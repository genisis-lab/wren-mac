# Mac app bug and security review — 13 November 2026

Reviewed the current Mac app after upstream PR #13, including credentials, authenticated networking, admin unlocks, PGP, cached mail, spreadsheet exports, HTML rendering and the updater. Tests use synthetic accounts, passwords and messages; no real mail is sent or live admin records changed.

## Fixed

- **Authenticated URL boundaries:** every request now validates scheme, host and effective port before attaching credentials. Server-provided JMAP URLs cannot send app passwords to another origin. A task delegate also blocks off-origin redirects for API calls, file uploads/downloads and push streams. Same-origin redirects retain the credentials they need. Wren expects mail and admin endpoints on its sign-in origin; cross-origin JMAP deployments require a separate explicit trust design.
- **Admin Lock races:** a late unlock or admin-data response cannot restore a locked session or repopulate it. Pending unlock challenges are revoked on explicit Lock, while an attempted admin call before verification leaves the pending challenge intact. Cancelled UI tasks do not reopen the panel.
- **PGP Lock races:** an in-progress private-key decryption cannot put a key back into the engine after Lock. The Swift layer also invalidates pending restore/unlock work, including work waiting for the hidden engine to start.
- **Keychain replacement:** existing credentials are updated in place. A denied or failed update leaves the previous app password or PGP backup intact, instead of deleting it first.
- **Malformed server numbers:** counts, quota exports and admin displays use nontrapping integer conversions. Out-of-range values do not crash the app.
- **Sign-out cache lifetime:** invalidated caches cannot be read or recreated by late responses. Repeated invalidation cannot delete a fresh sign-in's cache. The UI checks the active login identity before accepting late mail results.
- **CSV output:** CRLF inside a field is quoted correctly. Spreadsheet exports quote and prefix formula-like cells with a tab, including leading whitespace and full-width formula markers. The prefix is intentionally part of the export; CSV has no universal safe interpretation across every spreadsheet application. See [OWASP's CSV guidance](https://owasp.org/www-community/attacks/CSV_Injection).

## Verification

- WrenKit regression tests cover unsafe endpoints, redirects, delayed admin replies, malformed numbers, CSV structure and cache invalidation, alongside the existing suite.
- Two real loopback HTTP servers exercise every authenticated transport. The second origin receives zero requests; a same-origin POST redirect retains its method, credentials and body.
- Keychain failure injection covers existing-value updates, access denial, first saves and duplicate-item races without accessing the user's Keychain.
- The actual SwiftUI/WebKit reader renders a synthetic message while blocking its scripts, remote images/CSS/frames, refresh navigation and form submission.
- PGP tests cover encryption/decryption, valid signatures, incorrect passphrases, explicit locking and locking during decryption. CI rebuilds the bundled JavaScript and checks that it matches the committed source.
- `npm audit` reported zero vulnerabilities in the installed PGP dependency tree. Sparkle is pinned to 2.10.1; the five published [upstream security advisories](https://github.com/sparkle-project/Sparkle/security/advisories) checked during this review were patched in 2.9.6 or earlier.
- CI runs the tests and builds the app, widget and Share extension. Release builds additionally verify the universal executable, code signature, Sparkle archive signature, signed feed and embedded public key.

## Limits

This is a targeted source review with regression and runtime tests, not a claim that the app has no remaining vulnerabilities. The live-server integration test requires dedicated test credentials and is skipped in CI. Production administration, end-to-end mail delivery and server-side authorization were not exercised against the user's live account. The app remains ad-hoc signed without Apple notarization; Sparkle's signing requirements remain enabled.
