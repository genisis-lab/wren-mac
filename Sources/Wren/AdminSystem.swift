import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WrenKit

/// Admin → System & Backup: what the server runs on, its encryption key, backups and restores, and announcements.
struct AdminSystemPage: View {
    @Bindable var panel: AdminPanel
    @State private var system: AdminSystem?
    @State private var backups: AdminBackups?
    @State private var prompt: SystemPrompt?
    /// What a restore did; the panel locks once it's read (a restore ends every unlock).
    @State private var finished: String?

    var body: some View {
        Group {
            if let s = system {
                Form {
                    SystemInfo(panel: panel, s: s, prompt: $prompt)
                    AutoBackups(panel: panel, data: backups, prompt: $prompt)
                    ExportRestore(panel: panel, s: s, prompt: $prompt)
                    Announcement(panel: panel)
                }
                .formStyle(.grouped)
            } else {
                AdminLoading()
            }
        }
        .task(id: panel.generation) {
            system = await panel.fetch("/system")
            backups = await panel.fetch("/backups")
        }
        // While a backup runs, look again every few seconds.
        .task(id: running) {
            while running && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { backups = await panel.fetch("/backups") }
            }
        }
        .sheet(item: $prompt) { sheet($0) }
        .alert("Restore finished", isPresented: Binding(get: { finished != nil }, set: { if !$0 { finished = nil; panel.lock() } })) {
            Button("OK") {}
        } message: {
            Text(finished ?? "")
        }
    }

    private var running: Bool { backups?.backups.contains { $0.status == "running" } ?? false }

    @ViewBuilder private func sheet(_ p: SystemPrompt) -> some View {
        switch p {
        case .key(let mode):
            KeySheet(panel: panel, mode: mode)
        case .restoreBackup(let b):
            TypedConfirmSheet(
                title: "Restore the backup from \(adminDate(b.createdAt))?",
                message: "Every person, message and setting on this server is replaced with the backup. Everything since then is lost, and everyone, you included, is signed out.",
                phrase: "restore", action: "Restore"
            ) { try await restore(b, allowKeyMismatch: false) }
        case .mismatchBackup(let b):
            ConfirmSheet(title: "Restore it anyway?", message: keyMismatchMessage, action: "Restore Anyway") {
                try await restore(b, allowKeyMismatch: true)
            }
        case .restoreFile(let url):
            TypedConfirmSheet(
                title: "Restore from “\(url.lastPathComponent)”?",
                message: "Every person, message and setting on this server is replaced with what’s in the file. Everyone, you included, is signed out.",
                phrase: "restore", action: "Restore"
            ) { try await upload(url, allowKeyMismatch: false) }
        case .mismatchFile(let url):
            ConfirmSheet(title: "Restore it anyway?", message: keyMismatchMessage, action: "Restore Anyway") {
                try await upload(url, allowKeyMismatch: true)
            }
        case .rollBack(let date):
            TypedConfirmSheet(
                title: "Roll the database back to \(date.formatted(date: .abbreviated, time: .shortened))?",
                message: "Everything after that moment is undone, for everyone, and everyone is signed out.",
                phrase: "restore", action: "Restore to This Time"
            ) {
                try await panel.send("POST", "/restore-point", ["at": .number((date.timeIntervalSince1970 * 1000).rounded())], reload: false)
                let when = date.formatted(date: .abbreviated, time: .shortened)
                afterSheet { finished = "The database is rolling back to \(when). It takes a few seconds, and everyone is signed out: unlock the admin panel again then." }
            }
        case .deleteBackup(let b):
            ConfirmSheet(title: "Delete the backup from \(adminDate(b.createdAt))?", message: "It can’t be brought back.", action: "Delete Backup") {
                try await panel.send("DELETE", "/backups/\(b.id)")
                panel.notice = (text: "Backup deleted.", link: nil)
            }
        }
    }

    // No reload after a restore: it ended this unlock, and the next call would lock the panel before the result shows.

    private func restore(_ b: AdminBackup, allowKeyMismatch: Bool) async throws {
        do {
            let r = try await panel.send("POST", "/backups/\(b.id)/restore\(allowKeyMismatch ? "?allowKeyMismatch=1" : "")", reload: false)
            let text = restoredText(try r.decode(AdminRestored.self))
            afterSheet { finished = text }
        } catch let error where !allowKeyMismatch && isKeyMismatch(error) {
            afterSheet { prompt = .mismatchBackup(b) }
        }
    }

    private func upload(_ url: URL, allowKeyMismatch: Bool) async throws {
        do {
            let r = try await panel.upload("/restore\(allowKeyMismatch ? "?allowKeyMismatch=1" : "")", file: url, contentType: "application/x-ndjson", reload: false)
            let text = restoredText(try r.decode(AdminRestored.self))
            afterSheet { finished = text }
        } catch let error where !allowKeyMismatch && isKeyMismatch(error) {
            afterSheet { prompt = .mismatchFile(url) }
        }
    }
}

/// The sheets this page asks with: one at a time, from the page itself (a Section's modifiers reach each of its rows).
private enum SystemPrompt: Identifiable {
    case key(KeySheet.Mode)
    case restoreBackup(AdminBackup), mismatchBackup(AdminBackup), deleteBackup(AdminBackup)
    case restoreFile(URL), mismatchFile(URL)
    case rollBack(Date)

    var id: String {
        switch self {
        case .key(let m): "key-\(m.rawValue)"
        case .restoreBackup(let b): "restore-\(b.id)"
        case .mismatchBackup(let b): "mismatch-\(b.id)"
        case .deleteBackup(let b): "delete-\(b.id)"
        case .restoreFile(let u): "file-\(u.path)"
        case .mismatchFile(let u): "file-mismatch-\(u.path)"
        case .rollBack(let d): "back-\(d.timeIntervalSince1970)"
        }
    }
}

private struct SystemInfo: View {
    let panel: AdminPanel
    let s: AdminSystem
    @Binding var prompt: SystemPrompt?

    var body: some View {
        Section("System") {
            LabeledContent("Version", value: "Wren \(s.version)")
            if let p = s.platform { LabeledContent("Runtime", value: p) }
            if let b = s.blobStorage { LabeledContent("Message storage", value: b) }
            LabeledContent("Mail files") { files }
            LabeledContent("Incoming mail", value: s.selfHosted == true ? "Provider webhooks (Resend inbound, for example)" : "Cloudflare Email Routing to this Worker, plus any provider webhooks")
            LabeledContent("Cloudflare Email Service") {
                if let b = s.emailBindings, !b.isEmpty {
                    AdminBadge(text: "Binding \(b.joined(separator: ", ")) available", tone: .ok)
                } else if s.selfHosted == true {
                    Text("Only when deployed to Cloudflare").foregroundStyle(.secondary)
                } else {
                    AdminBadge(text: "No send_email binding in wrangler.toml", tone: .warn)
                }
            }
            if let up = s.uptime { LabeledContent("Up for", value: Self.duration(up)) }
            if let url = s.publicUrl { LabeledContent("Public URL") { Text(url).textSelection(.enabled) } }
            LabeledContent("Encryption key") { key }
            LabeledContent("Database size", value: adminBytes(s.storage?.database))
            LabeledContent("Message store size", value: adminBytes(s.storage?.blobs))
        }
    }

    @ViewBuilder private var files: some View {
        if let e = s.encryptingFiles {
            let skipped = e.skipped ?? 0
            if e.done == true {
                Text("Encrypted, except \(Self.fileCount(skipped)) that couldn’t be. They were left as they were and still open.").foregroundStyle(.secondary)
            } else if s.keyMismatch == true {
                Text("Encrypting existing mail files is paused until the original WREN_SECRET is back.").foregroundStyle(.secondary)
            } else {
                Text("Encrypting existing mail files\(e.left.map { ": \($0.formatted()) left" } ?? "…")\(skipped > 0 ? " (\(Self.fileCount(skipped)) couldn’t be and were left as they were)" : "")")
                    .foregroundStyle(.secondary)
            }
        } else {
            AdminBadge(text: "Encrypted", tone: .ok)
        }
    }

    @ViewBuilder private var key: some View {
        if s.keyMismatch == true {
            VStack(alignment: .trailing, spacing: 4) {
                AdminBadge(text: "WREN_SECRET changed: mail files and encrypted settings can’t be read", tone: .danger)
                if panel.isOwner { Button("Use the Current Key…") { prompt = .key(.useCurrent) }.controlSize(.small) }
            }
        } else if s.secretFromEnv == true {
            AdminBadge(text: "From WREN_SECRET", tone: .ok)
        } else {
            HStack {
                Text("Made by Wren, kept with the database").foregroundStyle(.secondary)
                if panel.isOwner { Button("Show Key…") { prompt = .key(.show) }.controlSize(.small) }
            }
        }
    }

    static func fileCount(_ n: Int) -> String { "\(n.formatted()) \(n == 1 ? "file" : "files")" }

    static func duration(_ ms: Double) -> String {
        Duration.milliseconds(Int64(ms)).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2))
    }
}

// MARK: Encryption key

/// The owner's own steps for the encryption key: their password (and 2-step code) again, even when unlocked.
private struct KeySheet: View {
    enum Mode: String, Identifiable { case show, useCurrent; var id: String { rawValue } }
    let panel: AdminPanel
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var code = ""
    @State private var key: String?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .show ? "Encryption Key" : "Use the Current Key?").font(.headline)
            if let key {
                CopyField(label: "Key", value: key)
                Text("Keep it somewhere safe, such as a password manager. When you move Wren or restore a backup somewhere else, set it as WREN_SECRET there first, or mail files and backups can’t be read.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Save to a File…") { save(key) }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Group {
                    if mode == .show {
                        Text("Wren made this key and keeps it only in the database. Mail files and stored backups can’t be read without it, so keep a copy somewhere safe.")
                    } else {
                        Text("Wren treats the current WREN_SECRET as this data’s key from now on, stops warning about it, and encrypts new mail files with it. Anything saved with the old key stays unreadable for good: provider credentials (enter them again under Providers), 2-step secrets (reset them for those people) and mail files stored with it. If you still have the old key, put it back as WREN_SECRET instead.")
                    }
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                SecureField("Your account password", text: $password)
                    .textFieldStyle(.roundedBorder)
                TextField("2-step code, if you use one", text: $code)
                    .textFieldStyle(.roundedBorder)
                SheetButtons(
                    error: error, busy: busy, action: mode == .show ? "Show Key" : "Use the Current Key", destructive: mode == .useCurrent,
                    disabled: password.isEmpty, cancel: { dismiss() }, perform: perform
                )
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func perform() {
        busy = true
        error = nil
        var body: [String: JSON] = ["password": .string(password)]
        let c = code.filter { !$0.isWhitespace }
        if !c.isEmpty { body["code"] = .string(c) }
        Task {
            defer { busy = false }
            do {
                if mode == .show {
                    key = try await panel.send("POST", "/encryption-key", .object(body))["key"]?.string
                    password = ""
                    code = ""
                } else {
                    try await panel.send("POST", "/encryption-key/use-current", .object(body))
                    panel.notice = (text: "Wren now uses the current key.", link: nil)
                    dismiss()
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func save(_ key: String) {
        let save = NSSavePanel()
        save.nameFieldStringValue = "wren-encryption-key.txt"
        save.allowedContentTypes = [.plainText]
        guard save.runModal() == .OK, let url = save.url else { return }
        do {
            try Data(key.utf8).write(to: url, options: .atomic)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: Backups

/// What a restore brought back.
private func restoredText(_ r: AdminRestored) -> String {
    let when = wrenDate(r.exportedAt)?.formatted(date: .abbreviated, time: .shortened) ?? "the backup"
    let skipped = r.skipped ?? 0
    return "Restored \(r.total.formatted()) records from \(when).\(skipped > 0 ? " \(skipped) couldn’t be restored." : "") Everyone was signed out: unlock the admin panel again to carry on."
}

/// After the confirmation sheet has gone: a sheet or alert asked for while another is closing doesn't show.
@MainActor
private func afterSheet(_ show: @escaping @MainActor () -> Void) {
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(450))
        show()
    }
}

/// A restore the server refused because the backup was made with another encryption key.
private func isKeyMismatch(_ error: Error) -> Bool {
    guard let e = error as? AdminError, case .server(409, let message, _) = e else { return false }
    return message == "key_mismatch"
}

private let keyMismatchMessage = "It was made with a different encryption key (WREN_SECRET). Provider credentials and 2-step secrets in it can’t be read here, and neither can mail files stored with that key. Restore anyway? 2-step sign-in is turned off for everyone and you’ll enter provider settings again. To keep them, set WREN_SECRET to the original server’s key first."

/// "2026-11-13-05-12-00", as the server names its files.
private func fileStamp(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
    return f.string(from: date)
}

/// Daily backups kept in storage, and backing up on demand.
private struct AutoBackups: View {
    let panel: AdminPanel
    let data: AdminBackups?
    @Binding var prompt: SystemPrompt?
    @State private var starting = false

    var body: some View {
        Section {
            if let data {
                settings(data)
                if data.backups.isEmpty { Text("No backups yet.").foregroundStyle(.secondary) }
                ForEach(data.backups) { row($0) }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            HStack {
                Text("Automatic backups")
                Spacer()
                Button(running ? "Backing Up…" : "Back Up Now") { backUp() }
                    .disabled(starting || running || data == nil)
                    .controlSize(.small)
            }
        } footer: {
            Text("A copy of the database is saved to storage every day. Message files are kept 30 days after they’re deleted, so a restore brings messages back whole.")
        }
    }

    private var running: Bool { data?.backups.contains { $0.status == "running" } ?? false }

    @ViewBuilder private func settings(_ d: AdminBackups) -> some View {
        Toggle(isOn: Binding(get: { d.settings.enabled }, set: { save(["backups.enabled": .bool($0)]) })) {
            Text("Back up every day")
            if d.settings.enabled, let next = d.nextAt { Text("Next: \(adminDate(next))") }
        }
        Picker("Time (UTC)", selection: Binding(get: { d.settings.hour }, set: { save(["backups.hour": .number(Double($0))]) })) {
            ForEach(0..<24, id: \.self) { h in Text(String(format: "%02d:00", h)).tag(h) }
        }
        .disabled(!d.settings.enabled)
        Picker("Keep", selection: Binding(get: { d.settings.keep }, set: { save(["backups.keep": .number(Double($0))]) })) {
            ForEach(Array(Set([3, 7, 14, 30, 60, d.settings.keep])).sorted(), id: \.self) { n in Text("The last \(n)").tag(n) }
        }
        .disabled(!d.settings.enabled)
    }

    private func row(_ b: AdminBackup) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(adminDate(b.createdAt)) · \(b.kind == "auto" ? "daily" : "by \(b.createdBy ?? "an admin")")")
                Text(detail(b)).font(.caption).foregroundStyle(b.status == "failed" ? Color.red : Color.secondary)
            }
            Spacer()
            AdminBadge(text: b.status == "done" ? "Ready" : b.status == "running" ? "Running" : "Failed", tone: b.status == "done" ? .ok : b.status == "running" ? .accent : .danger)
            if b.status == "done" {
                Button("Download…") { panel.download("/backups/\(b.id)/download", suggested: "wren-backup-\(fileStamp(wrenDate(b.createdAt) ?? .now)).jsonl") }
                if panel.isOwner { Button("Restore…") { prompt = .restoreBackup(b) } }
            }
            if b.status != "running" {
                Button { prompt = .deleteBackup(b) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete this backup")
                    .accessibilityLabel("Delete the backup from \(adminDate(b.createdAt))")
            }
        }
        .controlSize(.small)
    }

    private func detail(_ b: AdminBackup) -> String {
        switch b.status {
        case "done": "\((b.rows ?? 0).formatted()) records · \(adminBytes(b.bytes))"
        case "running": "In progress · \((b.rows ?? 0).formatted()) records so far"
        default: "Failed: \(b.error ?? "unknown error")"
        }
    }

    private func save(_ change: JSON) {
        panel.change("PUT", "/settings", change) { _ in (text: "Backup settings saved.", link: nil) }
    }

    private func backUp() {
        starting = true
        Task {
            defer { starting = false }
            do {
                try await panel.send("POST", "/backups")
            } catch {
                panel.error = error.localizedDescription
            }
        }
    }
}

/// Exports to keep anywhere, restoring one, and rolling the database back to a moment.
private struct ExportRestore: View {
    let panel: AdminPanel
    let s: AdminSystem
    @Binding var prompt: SystemPrompt?
    @State private var at = Date.now.addingTimeInterval(-3600)

    var body: some View {
        Section {
            HStack {
                Button("Download Export…") { panel.download("/export", suggested: "wren-export-\(fileStamp(.now)).jsonl") }
                if panel.isOwner { Button("Restore from an Export…") { choose() } }
                Spacer()
                if s.backup?.searchRebuilding == true { AdminBadge(text: "Rebuilding the search index…", tone: .warn) }
            }
            if panel.isOwner && s.backup?.pointInTime == true {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Point-in-time recovery").fontWeight(.medium)
                    Text("Roll the whole database back to any moment in the last 30 days, after an accidental bulk delete, say. Files deleted since are kept, so restored messages keep what they said.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        DatePicker("Moment to restore to", selection: $at, in: Date.now.addingTimeInterval(-30 * 86_400)...Date.now)
                            .labelsHidden()
                        Button("Restore to This Time…") { prompt = .rollBack(at) }
                    }
                }
            }
        } header: {
            Text("Backup & restore")
        } footer: {
            Text(s.selfHosted == true
                ? "Exports are portable copies of the database you can restore here or on Cloudflare. Message files live in the /data volume, so back that up too."
                : "Cloudflare keeps 30 days of history for the database. Exports are portable copies you can keep anywhere and restore here. Message files stay in R2.")
        }
    }

    private func choose() {
        let open = NSOpenPanel()
        open.allowsMultipleSelection = false
        open.canChooseDirectories = false
        open.message = "Choose a Wren export (.jsonl)"
        open.allowedContentTypes = ["jsonl", "ndjson", "json"].compactMap { UTType(filenameExtension: $0) }
        guard open.runModal() == .OK, let url = open.url else { return }
        prompt = .restoreFile(url)
    }
}

// MARK: Announcement

/// Email every active person, about planned maintenance for example.
private struct Announcement: View {
    let panel: AdminPanel
    @State private var subject = ""
    @State private var message = ""
    @State private var confirming = false
    @State private var busy = false

    var body: some View {
        Section {
            TextField("Subject", text: $subject)
            VStack(alignment: .leading, spacing: 4) {
                Text("Message")
                TextEditor(text: $message).frame(minHeight: 90)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Send Announcement…") { confirming = true }
                    .disabled(busy || subject.trimmingCharacters(in: .whitespaces).isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .confirmationDialog("Send this announcement to everyone?", isPresented: $confirming) {
                        Button("Send Announcement") { send() }
                    } message: {
                        Text("“\(subject)” goes to every active person on this server. It can’t be called back.")
                    }
            }
        } header: {
            Text("Announcement")
        } footer: {
            Text("Goes to everyone whose account is active, from the system sender, with replies to you.")
        }
    }

    /// Paragraphs at blank lines, line breaks kept, and nothing in it read as HTML.
    static func html(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
            .map { p in
                let safe = p.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                return "<p>\(safe.replacingOccurrences(of: "\n", with: "<br>"))</p>"
            }
            .joined()
    }

    private func send() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let r = try await panel.send("POST", "/announce", ["subject": .string(subject.trimmingCharacters(in: .whitespaces)), "html": .string(Self.html(message))])
                let n = r["recipients"]?.int ?? 0
                panel.notice = (text: "Announcement sent to \(n) \(n == 1 ? "person" : "people").", link: nil)
                subject = ""
                message = ""
            } catch {
                panel.error = error.localizedDescription
            }
        }
    }
}
