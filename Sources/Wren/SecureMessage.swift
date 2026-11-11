import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WrenKit

extension PGP.Opened {
    /// The email as it reads once decrypted or checked: these words instead of the PGP text, and none of its outer parts.
    func shown(in email: Email) -> Email {
        var e = email
        e.textBody = [BodyPart(partId: "pgp", size: 0, type: "text/plain")]
        e.htmlBody = html == nil ? nil : [BodyPart(partId: "pgp-html", size: 0, type: "text/html")]
        e.bodyValues = ["pgp": BodyValue(value: text ?? html.map(plainText(fromHTML:)) ?? "")]
        if let html { e.bodyValues?["pgp-html"] = BodyValue(value: html) }
        e.attachments = []
        return e
    }
}

/// An encrypted or signed message, as the web app shows it: decrypted with your key (once it's unlocked), and with
/// a line saying whether the signature checks out against the key Wren knows for the sender.
struct PGPMessageView: View {
    let email: Email
    let kind: PGPKind
    @Environment(MailStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @State private var opened: PGP.Opened?
    @State private var hasKey: Bool?
    @State private var problem: String?

    private var login: Login? { store.threadPlace.flatMap { store.login($0.login) } }
    private var isUnlocked: Bool { login.map { PGP.shared.unlocked.contains($0.id) } ?? false }
    private var sender: String { email.from?.first?.email ?? "the sender" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            banner
            if let opened {
                // Remote pictures stay off in encrypted and signed mail, so opening it tells nobody.
                MessageBody(email: opened.shown(in: email), html: opened.html.map { Trackers.strip($0).html }, allowRemote: false)
                DecryptedFiles(files: opened.files, sealed: kind == .encrypted ? email.files.filter(\.isSealed) : [])
                // Files outside what was signed or encrypted (not for PGP/MIME, whose parts are the message itself).
                let outside = kind == .encrypted || kind == .signed ? email.files.filter { !$0.isSealed } : []
                if !outside.isEmpty { AttachmentList(files: outside) }
            } else if kind.isEncrypted && !isUnlocked {
                locked
            } else if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: isUnlocked) { await open() }
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: 4) {
            if kind.isEncrypted { Label("Encrypted with PGP", systemImage: "lock.fill") }
            switch opened?.signature {
            case .valid: Label("Signed by \(sender)", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            case .bad: Label("The signature doesn’t match: this message may have been changed.", systemImage: "xmark.seal.fill").foregroundStyle(.red)
            case .unknown: Label("Signed with a key Wren doesn’t know for \(sender).", systemImage: "questionmark.diamond").foregroundStyle(.secondary)
            case nil: EmptyView()
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var locked: some View {
        if hasKey == false {
            VStack(alignment: .leading, spacing: 8) {
                Text("To read it, restore your PGP key in Settings → Encryption.")
                Button("Open Encryption Settings") {
                    UserDefaults.standard.set("encryption", forKey: "settingsTab")
                    openSettings()
                }
            }
        } else if let login {
            VStack(alignment: .leading, spacing: 8) {
                Text("Unlock your PGP key to read it.")
                Button("Unlock…") { Task { _ = await PGP.shared.unlockAsking(login) } }
            }
        }
    }

    private func open() async {
        if let known = store.decrypted[email.id] { return opened = known }
        guard let login else { return }
        hasKey = await PGP.shared.key(login) != nil
        guard !kind.isEncrypted || PGP.shared.unlocked.contains(login.id) else { return }
        do {
            let o = try await store.openPGP(email, kind)
            if kind.isEncrypted { store.decrypted[email.id] = o }
            opened = o
        } catch {
            problem = error.localizedDescription
        }
    }
}

extension BodyPart {
    /// An attachment encrypted on its own (name.pgp), as Wren and other apps send them with inline PGP.
    var isSealed: Bool { (name ?? "").lowercased().hasSuffix(".pgp") }
}

/// Files that came out of an encrypted or signed message, or are encrypted on their own: opened or saved decrypted.
struct DecryptedFiles: View {
    let files: [PGP.Opened.File]
    let sealed: [BodyPart]
    @Environment(MailStore.self) private var store

    var body: some View {
        if !files.isEmpty || !sealed.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(files, id: \.self) { file in
                    row(file.name, type: file.type, size: file.data.count) { file.data }
                }
                ForEach(sealed, id: \.self) { part in
                    row(String((part.name ?? "Attachment.pgp").dropLast(4)), type: "application/octet-stream", size: part.size) {
                        guard let login = store.threadPlace.flatMap({ store.login($0.login) }) else { throw NotConnected() }
                        return try await PGP.shared.decryptFile(store.download(part), login: login.id).data
                    }
                }
            }
        }
    }

    private func row(_ name: String, type: String, size: Int, data: @escaping () async throws -> Data) -> some View {
        Button {
            Task {
                do {
                    NSWorkspace.shared.open(try MailStore.temporaryFile(name, await data()))
                } catch {
                    store.alert = error.localizedDescription
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (name as NSString).pathExtension) ?? UTType(mimeType: type) ?? .data))
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).lineLimit(1).truncationMode(.middle)
                    Label(Int64(size).formatted(.byteCount(style: .file)), systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(name)
        .contextMenu {
            Button("Save to Downloads") {
                Task {
                    do { store.saveToDownloads(name, try await data()) } catch { store.alert = error.localizedDescription }
                }
            }
        }
        .accessibilityLabel("Open \(name), decrypted")
    }
}
