import Sparkle
import SwiftUI

/// Updates with Sparkle 2: Check for Updates… in the Wren menu, and Sparkle's own daily check once you allow it.
/// The feed is the newest GitHub release's appcast.xml (SUFeedURL), and an update must be signed with the key whose
/// public half is SUPublicEDKey (README.md, Releases).
@MainActor @Observable
final class Updates {
    static let shared = Updates()

    private(set) var canCheck = false
    private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var watching: NSKeyValueObservation?

    private init() {
        // Off in debug builds (so the screenshot run never sees Sparkle's questions), and without a public key,
        // which Sparkle would refuse to start with.
        #if DEBUG
        let configured = false
        #else
        let configured = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.isEmpty == false
        #endif
        controller = configured ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil
        watching = controller?.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let can = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = can }
        }
    }

    func check() {
        controller?.checkForUpdates(nil)
    }
}

struct UpdateCommands: Commands {
    let updates: Updates

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.check() }
                .disabled(!updates.canCheck)
        }
    }
}
