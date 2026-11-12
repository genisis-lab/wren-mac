# Wren for Mac

A native Mac mail app for [Wren](https://github.com/genisis-lab/mail), written in SwiftUI.
It signs in with an app password and talks to your Wren server over JMAP
([docs/jmap.md](https://github.com/genisis-lab/mail/blob/claude/wren-mail/docs/jmap.md)), so
mail apps have to be turned on in Wren (Admin → Settings & policies → Security).

- Several Wren accounts (Settings → Accounts), with All Inboxes at the top of the sidebar
- Mailboxes, labels and shared mailboxes in the sidebar, with unread counts and a Dock badge
- Opens with your mail showing, and shows what you've looked at when you're offline: the last list
  of each mailbox and the 150 conversations you opened most recently are kept on your Mac. What you
  move, read, flag, label or snooze offline is sent when Wren can be reached again (even after quitting)
- Conversations, search as you type with the matching words marked (in the mailbox you're looking at,
  or All Mailboxes), and a reader that folds older messages
- Double-click a conversation (or ⌘O) to open it in a window of its own; Print (⌘P); find words in a
  conversation (⌘F, then ⌘G); Raw Source (⌥⌘U) shows a message exactly as it arrived; View → Bigger
  and Smaller (⌘+, ⌘-) change the size of message text
- Show only unread mail (⌘L, or the filter button above the list)
- Archive, Trash, Junk, Move to Inbox (and Move to), flag, read/unread, labels and snooze, from the
  toolbar, the Message menu, swipes, right-click and VoiceOver's actions; moves can be undone with ⌘Z.
  Drag conversations onto a mailbox or label in the sidebar
- Right-click a mailbox to mark everything in it as read, or to empty the Trash or Junk; make, rename
  and delete labels there too
- Compose in its own window: reply, reply all, forward (with attachments), attach files (or drop
  them on the window), send now or later. Drafts are saved every 30 seconds while you write, and when
  the window closes. Your signature from Wren keeps its formatting and changes with the From address
- Undo Send: a sent message waits a few seconds (Settings → General) so ⌘Z or the Undo bar can stop it.
  Mailbox → Scheduled Messages… shows everything waiting to go out, to stop or change
- A reminder before sending without a subject, or without an attachment you mention
- Formatting as you write: bold, italic, underline (⌘B, ⌘I, ⌘U), links (⌘K), bulleted and numbered
  lists and quotes. It's sent as HTML with a plain-text copy, and replies keep the quoted message's HTML
- Calendar invitations show a card with what, when, where and who's asking, and Accept, Maybe and
  Decline (with a comment) send your answer to the organizer
- Mailing-list mail has an Unsubscribe button: Wren asks the list or writes to it for you, as on the web
  (with a Wren server that has it)
- Send as a private link that stops working after 1, 7 or 30 days, as on the web
- PGP, the same as Wren on the web (Settings → Encryption): restore your key from the backup you made
  in Wren, read encrypted mail (inline and PGP/MIME) and check signatures, and encrypt and sign what
  you send when Wren knows a key for everyone you write to
- Address suggestions as you type, from your Wren contacts and the mail you've loaded
- Attachments: click to select, Space for Quick Look, double-click to open, drag to the Finder
- Wren can be your default email app (Settings → General), so `mailto:` links open a new message
- Out-of-office reply (Settings → Out of Office) and storage used (Settings → Account), with a
  warning in the sidebar when your mailbox is nearly full
- Live updates over Wren's push stream, fetching only what changed, and reconnecting as soon as the Mac
  wakes or the network is back; a notification for new mail in your Inbox that opens
  the conversation when you click it, with Reply (type it right in the notification), Archive and
  Mark as Read buttons; a notification goes away once its mail is read or filed, here or anywhere else
- Conversations you've looked at show up in Spotlight (sender, subject and preview) and open in Wren
- Share → Wren from any app: files become a new message with them attached (as when you drop them
  on Wren's Dock icon), links and text a new message with them in it
- A widget with the unread mail in each Inbox (small and medium; it needs a team, see Building)
- Shortcuts: Send Email (opened to check, or sent straight away), Get Unread Count and Open Mailbox,
  also from Spotlight and Siri
- Updates itself (Wren → Check for Updates…, and hourly automatic checks), from this
  repository's releases
- Mail's keyboard shortcuts (⌘N, ⌘R, ⇧⌘R, ⇧⌘F, ⇧⌘D, ⌃⌘A, ⇧⌘U, ⇧⌘L, ⇧⌘J, ⇧⌘N)

## Privacy and security

- Each account's app password is kept in your login keychain. The server address must be `https`
  (plain `http` only works for `localhost`).
- The mail kept for offline use is in `~/Library/Application Support/Wren/Cache`, one folder per
  account, and is deleted when you remove the account.
- HTML mail is shown with JavaScript off, no cookies or storage, and a Content-Security-Policy
  that blocks everything from the web until you click **Load Remote Content** (or turn it on
  in Settings → Viewing). Links open in your browser.
- Tracking pictures (tiny or hidden images, and known open trackers) are taken out of every
  message, even with remote content on, and the reader says how many. Links lose their tracking
  parameters (`utm_*`, `fbclid` and the like) and known redirect wrappers before they open. These
  are the same rules as Wren on the web.
- Attachments you open are saved with the quarantine flag, so Gatekeeper checks them.
- The editor is a web page with its scripts off, so nothing in a quoted message runs, and nothing loads
  from the web while you write.
- PGP uses OpenPGP.js 6.3.2, the same as Wren on the web, built into the app (`Resources/pgp.js`, made
  from `pgp/` with `npm ci && npm run build`); it's never downloaded. It runs in a hidden web page that
  can't reach the network. Your private key is kept in your login keychain still protected by its
  passphrase; the passphrase unlocks it in memory until you quit or choose Lock, and is never saved.
  Encrypted mail is shown without remote pictures, and drafts written with Encrypt on are saved encrypted.
- Spotlight's index of your conversations stays on your Mac, and each account's entries are deleted
  when you remove the account.

## Building

You need macOS 14 (Sonoma) or later and Xcode 16 or later.

**To try it:** open `Wren.xcodeproj` in Xcode, pick the **Wren** scheme and **My Mac**, and
press ⌘R.

**To use it:** run `./bundle.sh`. It builds `build/Wren.app`, signed for your own Mac; drag
it into Applications. The version it shows is `MARKETING_VERSION` in `project.yml`.

The project is made from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen): after
changing that file (or adding a source file), run `xcodegen generate`. CI does too, and commits the
project when it changed. The mail engine (`Sources/WrenKit`) is a Swift package of its own, which the
project uses. The app icon is drawn in `Design/AppIcon.svg` (Wren's web icon on the macOS icon grid);
the PNGs in `Sources/Wren/Assets.xcassets` are made from it.

**The widget needs your team ID.** The app hands the widget its unread counts through an App Group,
and on the Mac an App Group's name starts with the team ID it's signed with. Signed for this Mac only
(no team), there's no group, so the widget only says to open Wren. Sign with your team from a free or
paid Apple Developer account, in Xcode (Signing & Capabilities, for each of the three targets) or with

```sh
TEAM=ABCDE12345 SIGN_IDENTITY="Apple Development" ./bundle.sh
```

The team is also written into the app and the widget (`WrenTeam` in their Info.plist), which is how
they find the group.

**To share it** with other people, sign it with a Developer ID certificate (from a paid
Apple Developer account) and have Apple notarize it, or Gatekeeper will refuse to open it:

```sh
TEAM=ABCDE12345 SIGN_IDENTITY="Developer ID Application" ./bundle.sh
ditto -c -k --keepParent build/Wren.app build/Wren.zip
xcrun notarytool submit build/Wren.zip --keychain-profile <profile> --wait
xcrun stapler staple build/Wren.app
```

(`xcrun notarytool store-credentials` creates the keychain profile once.) Releases do all of this for you,
see below. The app isn't sandboxed, so it can't go on the Mac App Store as it is.

## Releases and in-app updates

The **Release** workflow tests and builds every push to `main`, each numeric version tag (`v0.2.0`),
and manual runs on `main`. A successful run publishes a universal Apple Silicon / Intel app and a signed
`appcast.xml` on GitHub Releases. Failed tests, builds, or signature checks prevent publication.
Build numbers use the GitHub run ID; a retry of an older run cannot replace a newer release as latest.
For main builds, the displayed version comes from `MARKETING_VERSION` in `project.yml`.

No paid Apple Developer membership is needed. The app is ad-hoc signed, **not notarized by Apple**.
People installing the first download may need to approve it in System Settings → Privacy & Security →
Open Anyway. Managed Macs can prohibit this. A system administrator password can be requested when
replacing an app requires additional permissions; Wren never collects that password.
The widget's shared unread counts still require Apple team signing.

Wren → **Check for Updates…** checks immediately. Release builds also check hourly while Wren is running,
and offer an Install Update choice. Settings → General allows automatic checks to be turned off.
Debug builds do not check. Update archives are verified before extraction, and feeds are signed too.
An existing local build with no update key needs one manual replacement with an updater-enabled build.

### Signing configuration

The public key is committed in `project.yml`. The matching **private** key belongs only in the maintainer's
Keychain and the `SPARKLE_PRIVATE_KEY` GitHub Actions secret. Never commit or log the private key.
This repository uses the Sparkle Keychain account `io.github.genisis-lab.wren`.
The tools are in the Sparkle distribution's `bin` directory (also supplied by its Swift package).

For a new fork, generate your own key with `generate_keys --account <your-app-id>`, embed its public key,
and securely transfer its exported private key into your own repository's Actions secret.
Keep a secure backup: losing this key prevents existing installations from trusting future updates.
Do not replace a deployed key as part of a routine release.

The release workflow verifies both signatures and confirms that the built app embeds the matching public
key before publishing. It uses the Sparkle version pinned by the Xcode project.

## Tests

The mail engine (`Sources/WrenKit`: the JMAP client, models and compose helpers) uses only
Foundation, so its tests run on macOS and Linux:

```sh
swift test
```

`LiveServerTests` also runs everything the app does against a real Wren server, when you
give it one with mail in its inbox. Use a test server (such as Wren run locally from its own
repo): it sends, snoozes and deletes.

```sh
WREN_SERVER=http://localhost:8787 WREN_USER=you@example.com WREN_APP_PASSWORD=wren_… swift test
```

## Screenshots

The **Screenshots** workflow (Actions → Screenshots → Run workflow, or the `screenshots` label on a
pull request) runs a debug build against Wren with sample mail on a Mac runner and saves each
screen, light and dark. They're attached to the run, and pushed to a `screens/<run id>` branch
(only the newest run's branch is kept). The driver is `Sources/Wren/Demo.swift`, which is only in
debug builds and only runs when `WREN_DEMO_OUT` is set.

## Not yet

Pictures pasted on their own aren’t put in the message (attach them instead). Files you add with Encrypt on
are encrypted when the message is sent, not as you add them (the web app does both).
