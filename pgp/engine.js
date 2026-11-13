// Wren for Mac's PGP engine: the same OpenPGP.js and postal-mime the web app uses (genisis-lab/mail,
// src/web/lib/pgp.ts), doing the same things. It runs in a hidden WKWebView (Sources/Wren/PGP.swift) that loads
// nothing from the web; the app calls `wren.<name>(…)` and gets back { value } or { error }. Bytes cross as base64.
// Unlocked keys live only in this page's memory, until the app quits or locks them.
import * as openpgp from 'openpgp';
import PostalMime from 'postal-mime';

const unlocked = new Map(); // sign-in → PrivateKey
const unlockAttempts = new Map(); // sign-in → latest attempt; Lock invalidates pending decryptions too

const fromBase64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
function toBase64(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i += 8192) s += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(s);
}

function keyFor(login) {
  const key = unlocked.get(login);
  if (!key) throw new Error('Unlock your PGP key first');
  return key;
}

async function readKeys(armored) {
  const keys = await Promise.all(armored.map((a) => openpgp.readKey({ armoredKey: a }).catch(() => null)));
  return keys.filter((k) => !!k);
}

async function readAnyMessage(data) {
  if (typeof data === 'string') return openpgp.readMessage({ armoredMessage: data });
  const head = new TextDecoder().decode(data.subarray(0, 100));
  return /-----BEGIN PGP MESSAGE-----/.test(head) ? openpgp.readMessage({ armoredMessage: new TextDecoder().decode(data) }) : openpgp.readMessage({ binaryMessage: data });
}

/** valid: signed by a key known for the sender. bad: that key, but it doesn't check out. unknown: a key you don't have. */
async function signatureStatus(signatures, keys) {
  const checked = await Promise.all(signatures.map((s) => s.verified.then(() => true, () => false)));
  if (!signatures.length) return null;
  const known = signatures.find((s) => keys.some((k) => k.getKeys(s.keyID).length));
  if (!known) return 'unknown';
  return checked[signatures.indexOf(known)] ? 'valid' : 'bad';
}

/** RFC 3156: what a multipart/signed message signs is its first part exactly as sent, with CRLF line ends. */
function signedPart(raw) {
  let s = '';
  for (let i = 0; i < raw.length; i += 8192) s += String.fromCharCode(...raw.subarray(i, i + 8192));
  const header = /^content-type:[ \t]*multipart\/signed((?:[^\r\n]|\r?\n[ \t])*)/im.exec(s);
  const boundary = header && /boundary="?([^";\r\n]+)"?/i.exec(header[1])?.[1];
  if (!header || !boundary) return null;
  const delimiter = `--${boundary}`;
  const first = s.indexOf(delimiter, header.index + header[0].length);
  const start = first === -1 ? -1 : s.indexOf('\n', first) + 1;
  const end = start > 0 ? s.indexOf(`\n${delimiter}`, start) : -1;
  if (end === -1) return null;
  const part = s.slice(start, end).replace(/\r$/, '').replace(/\r?\n/g, '\r\n');
  return Uint8Array.from(part, (ch) => ch.charCodeAt(0));
}

async function verifyDetachedBytes(data, armoredSignature, senderKeys) {
  const signature = await openpgp.readSignature({ armoredSignature });
  const keys = await readKeys(senderKeys);
  const textMode = signature.packets[0]?.signatureType === openpgp.enums.signature.text;
  const message = await (textMode ? openpgp.createMessage({ text: new TextDecoder().decode(data) }) : openpgp.createMessage({ binary: data }));
  const r = await openpgp.verify({ message, signature, verificationKeys: keys });
  return (await signatureStatus(r.signatures, keys)) ?? 'unknown';
}

const files = (list) => list.map((a) => ({ filename: a.filename || 'attachment', contentType: a.mimeType || 'application/octet-stream', data: toBase64(new Uint8Array(a.content)) }));

async function describe(key) {
  return { fingerprint: key.getFingerprint().toUpperCase(), userIds: key.getUserIDs(), publicKey: key.toPublic().armor() };
}

const api = {
  /** A private key's fingerprint, names and public key, without unlocking it. */
  async keyInfo(armored) {
    return describe(await openpgp.readPrivateKey({ armoredKey: armored }));
  },

  /** A backed-up key: it must be passphrase-protected, and the passphrase must open it. Keeps it unlocked for `login`. */
  async unlock(login, armored, passphrase) {
    const attempt = {};
    unlockAttempts.set(login, attempt);
    const key = await openpgp.readPrivateKey({ armoredKey: armored }).catch(() => {
      throw new Error('That isn’t a PGP private key');
    });
    if (key.isDecrypted()) throw new Error('The key backup is not passphrase-protected');
    const open = await openpgp.decryptKey({ privateKey: key, passphrase }).catch(() => {
      throw new Error('That passphrase didn’t work');
    });
    if (unlockAttempts.get(login) !== attempt) throw new Error('The PGP key was locked. Unlock it again.');
    unlocked.set(login, open);
    return describe(key);
  },

  lock(login) {
    if (login) {
      unlocked.delete(login);
      unlockAttempts.delete(login);
    } else {
      unlocked.clear();
      unlockAttempts.clear();
    }
    return true;
  },

  /** The keys that can still be encrypted to (not expired or revoked). */
  async usableKeys(armored) {
    const ok = await Promise.all(armored.map((a) => openpgp.readKey({ armoredKey: a }).then((k) => k.getEncryptionKey().then(() => true)).catch(() => false)));
    return armored.filter((_, i) => ok[i]);
  },

  /** Hides recipient key IDs as well as addresses, including those of Bcc recipients. Signs when `sign` is set. */
  async encryptText(login, text, keys, sign) {
    return openpgp.encrypt({ message: await openpgp.createMessage({ text }), encryptionKeys: await readKeys(keys), signingKeys: sign ? keyFor(login) : undefined, wildcard: true });
  },

  /** An attachment as a binary .pgp file; the original name travels inside it. */
  async encryptFile(login, data, filename, keys, sign) {
    const bytes = await openpgp.encrypt({
      message: await openpgp.createMessage({ binary: fromBase64(data), filename }),
      encryptionKeys: await readKeys(keys),
      signingKeys: sign ? keyFor(login) : undefined,
      wildcard: true,
      format: 'binary',
    });
    return toBase64(bytes);
  },

  /** Cleartext-signed text: readable anywhere, checkable with your public key. */
  async signText(login, text) {
    return openpgp.sign({ message: await openpgp.createCleartextMessage({ text }), signingKeys: keyFor(login) });
  },

  /** An inline PGP message; `senderKeys` check a signature inside it. */
  async decryptText(login, armored, senderKeys) {
    const verificationKeys = await readKeys(senderKeys);
    const r = await openpgp.decrypt({ message: await readAnyMessage(armored), decryptionKeys: keyFor(login), verificationKeys });
    return { text: r.data, signature: await signatureStatus(r.signatures, verificationKeys) };
  },

  /** An encrypted attachment (name.pgp): the file and its name. */
  async decryptFile(login, data) {
    const r = await openpgp.decrypt({ message: await readAnyMessage(fromBase64(data)), decryptionKeys: keyFor(login), format: 'binary' });
    return { data: toBase64(r.data), filename: r.filename || '' };
  },

  /** A PGP/MIME message (its encrypted.asc part): inside is a whole MIME message, read with postal-mime. */
  async decryptMime(login, data, senderKeys) {
    const verificationKeys = await readKeys(senderKeys);
    const r = await openpgp.decrypt({ message: await readAnyMessage(fromBase64(data)), decryptionKeys: keyFor(login), verificationKeys, format: 'binary' });
    let email = await PostalMime.parse(r.data, { attachmentEncoding: 'arraybuffer' });
    // Signed, then encrypted as a second layer: what's inside is itself multipart/signed.
    const sig = email.attachments.find((a) => a.mimeType === 'application/pgp-signature');
    let signature = await signatureStatus(r.signatures, verificationKeys);
    const signed = sig && !signature ? signedPart(r.data) : null;
    if (sig && signed) {
      signature = await verifyDetachedBytes(signed, new TextDecoder().decode(sig.content), senderKeys);
      email = await PostalMime.parse(signed, { attachmentEncoding: 'arraybuffer' });
    }
    return { text: email.text ?? null, html: email.html ?? null, attachments: files(email.attachments.filter((a) => a !== sig)), signature };
  },

  /** A cleartext-signed message: the text that was signed, and whether the signature checks out. */
  async verifyCleartext(armored, senderKeys) {
    const message = await openpgp.readCleartextMessage({ cleartextMessage: armored });
    const keys = await readKeys(senderKeys);
    const r = await openpgp.verify({ message, verificationKeys: keys });
    return { text: message.getText(), signature: (await signatureStatus(r.signatures, keys)) ?? 'unknown' };
  },

  /** A PGP/MIME signed message: only the part whose bytes were checked is shown, never an unsigned outer wrapper. */
  async verifySignedMime(raw, signature, senderKeys) {
    const part = signedPart(fromBase64(raw));
    if (!part) throw new Error('This message’s signed part couldn’t be found');
    const status = await verifyDetachedBytes(part, signature, senderKeys);
    const email = await PostalMime.parse(part, { attachmentEncoding: 'arraybuffer' });
    return { text: email.text ?? null, html: email.html ?? null, attachments: files(email.attachments), signature: status };
  },
};

globalThis.wren = Object.fromEntries(
  Object.entries(api).map(([name, fn]) => [
    name,
    async (...args) => {
      try {
        return { value: await fn(...args) };
      } catch (err) {
        return { error: err?.message || String(err) };
      }
    },
  ]),
);
