# Wren for Mac

A native Mac mail app for [Wren](https://github.com/genisis-lab/mail), written in SwiftUI.
It signs in with an app password and talks to your Wren server over JMAP
([docs/jmap.md](https://github.com/genisis-lab/mail/blob/claude/wren-mail/docs/jmap.md)), so
mail apps have to be turned on in Wren (Admin → Settings & policies → Security).

- Mailboxes, labels and shared mailboxes in the sidebar, with unread counts and a Dock badge
- Conversations, search as you type with the matching words marked, and a reader that folds older messages
- Archive, Trash, Junk, flag, read/unread, labels and snooze, from the toolbar, the Message
  menu, swipes and right-click; moves can be undone with ⌘Z
- Compose in its own window: reply, reply all, forward (with attachments), attach files (or drop
  them on the window), send now or later; closing a window with changes saves it to Drafts
- Address suggestions as you type, from your Wren contacts and the mail you've loaded
- Attachments: click to select, Space for Quick Look, double-click to open, drag to the Finder
- Wren can be your default email app (Settings → General), so `mailto:` links open a new message
- Out-of-office reply (Settings → Out of Office) and storage used (Settings → Account), with a
  warning in the sidebar when your mailbox is nearly full
- Live updates over Wren's push stream, and a notification for new mail in your Inbox that opens
  the conversation when you click it
- Mail's keyboard shortcuts (⌘N, ⌘R, ⇧⌘R, ⇧⌘F, ⇧⌘D, ⌃⌘A, ⇧⌘U, ⇧⌘L, ⇧⌘J, ⇧⌘N)

## Privacy and security

- The app password is kept in your login keychain. The server address must be `https`
  (plain `http` only works for `localhost`).
- HTML mail is shown with JavaScript off, no cookies or storage, and a Content-Security-Policy
  that blocks everything from the web until you click **Load Remote Content** (or turn it on
  in Settings → Viewing). Links open in your browser.
- Tracking pictures (tiny or hidden images, and known open trackers) are taken out of every
  message, even with remote content on, and the reader says how many. Links lose their tracking
  parameters (`utm_*`, `fbclid` and the like) and known redirect wrappers before they open. These
  are the same rules as Wren on the web.
- Attachments you open are saved with the quarantine flag, so Gatekeeper checks them.

## Building

You need macOS 14 (Sonoma) or later and Xcode 16 or later.

**To try it:** open `Package.swift` in Xcode, pick the **Wren** scheme and **My Mac**, and
press ⌘R. Notifications need a real app bundle, so they're off when run this way.

**To use it:** run `./bundle.sh`. It builds `build/Wren.app`, signed for your own Mac; drag
it into Applications. The version it shows is `CFBundleShortVersionString` in
`Info.plist`.

**To share it** with other people, sign it with a Developer ID certificate (from a paid
Apple Developer account) and have Apple notarize it, or Gatekeeper will refuse to open it:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./bundle.sh
ditto -c -k --keepParent build/Wren.app build/Wren.zip
xcrun notarytool submit build/Wren.zip --keychain-profile <profile> --wait
xcrun stapler staple build/Wren.app
```

(`xcrun notarytool store-credentials` creates the keychain profile once.) The app isn't
sandboxed, so it can't go on the Mac App Store as it is.

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

Several Wren sign-ins at once, an app icon and a rich-text editor.
