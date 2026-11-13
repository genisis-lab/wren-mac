import assert from 'node:assert/strict';
import { test } from 'node:test';
import * as openpgp from 'openpgp';
import './engine.js';

const wren = globalThis.wren;
const password = 'only-a-test-key';
const { privateKey, publicKey } = await openpgp.generateKey({
  type: 'ecc', curve: 'curve25519Legacy', userIDs: [{ name: 'Test', email: 'test@example.invalid' }], passphrase: password,
});

test('PGP round trip, signatures, wrong password and lock', async () => {
  assert.ok((await wren.unlock('a', privateKey, 'wrong')).error);
  assert.ok((await wren.unlock('a', privateKey, password)).value);
  const encrypted = await wren.encryptText('a', 'private test', [publicKey], true);
  assert.ok(encrypted.value);
  const decrypted = await wren.decryptText('a', encrypted.value, [publicKey]);
  assert.deepEqual(decrypted.value, { text: 'private test', signature: 'valid' });
  await wren.lock('a');
  assert.ok((await wren.signText('a', 'must remain locked')).error);
});

test('Lock invalidates an unlock already decrypting its private key', async () => {
  for (const lockTarget of ['a', null]) {
    const pending = wren.unlock('a', privateKey, password);
    await wren.lock(lockTarget);
    assert.ok((await pending).error);
    assert.ok((await wren.signText('a', 'must remain locked')).error);
  }
  assert.ok((await wren.unlock('a', privateKey, password)).value);
  assert.ok((await wren.signText('a', 'a fresh unlock works')).value);
  await wren.lock(null);
});
