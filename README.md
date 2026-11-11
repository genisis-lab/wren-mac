# Wren for Mac

A native Mac mail app for [Wren](https://github.com/genisis-lab/mail), written in SwiftUI.
It signs in with an app password and talks to your Wren server over JMAP
([docs/jmap.md](https://github.com/genisis-lab/mail/blob/claude/wren-mail/docs/jmap.md)), so
mail apps have to be turned on in Wren (Admin → Settings & policies → Security).

- Several Wren accounts (Settings → Accounts), with All Inboxes at the top of the sidebar
- Mailboxes, labels and shared mailboxes in the sidebar, with unread counts and a Dock badge
- Opens with your mail showing, and shows what you've looked at when you're offline: the last list
  of each mailbox and the 150 conversations you opened most recently are kept on your Mac
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
  the conversation when you click it, with Reply (type it right in the notification), Archive and
  Mark as Read buttons
- Conversations you've looked at show up in Spotlight (sender, subject and preview) and open in Wren
- Share → Wren from any app: files become a new message with them attached (as when you drop them
  on Wren's Dock icon), links and text a new message with them in it
- A widget with the unread mail in each Inbox (small and medium; it needs a team, see Building)
- Shortcuts: Send Email (opened to check, or sent straight away), Get Unread Count and Open Mailbox,
  also from Spotlight and Siri
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

A rich-text editor.
