import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WrenKit

/// A message window, as in Mail. Closing it with changes saves it to Drafts; the trash button throws it away.
struct ComposeView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// The window's value, kept up to date so a window restored after quitting comes back as it was.
    @Binding var value: Draft?
    @State private var draft: Draft
    /// The draft as opened or last saved, to tell whether closing should save it.
    @State private var saved: Draft
    @State private var showBcc: Bool
    @State private var busy = false
    @State private var uploading = 0
    @State private var error: String?
    @State private var picking = false
    @State private var scheduling = false
    @State private var sendAt = Date.now.addingTimeInterval(3600)
    /// Sent or deleted: nothing to save on close.
    @State private var done = false
    /// Addresses for what's being typed in the focused address field, and the one Return picks.
    @State private var suggestions: [EmailAddress] = []
    @State private var suggestion = 0
    @FocusState private var focus: Field?
    @State private var editor = EditorController()
    @State private var format = FormatState()
    /// Changed to start the editor over with the draft's text (after an encrypted draft is opened).
    @State private var editorVersion = 0
    /// With Encrypt on: who has no PGP key Wren knows.
    @State private var missingKeys: [String] = []
    @State private var confirmingPlain = false
    /// The background saves to Drafts (sending and closing wait for one under way, so the two don't both make a draft).
    @State private var copy = DraftCopy()

    enum Field: Hashable { case to, cc, bcc, subject }

    init(value: Binding<Draft?>) {
        _value = value
        let d = value.wrappedValue ?? Draft(accountId: "")
        _draft = State(initialValue: d)
        _saved = State(initialValue: d)
        _showBcc = State(initialValue: !d.bcc.isEmpty)
    }

    private var identities: [Identity] { store.identities(for: draft) }

    private func address(_ field: Field?) -> Binding<String>? {
        switch field {
        case .to: $draft.to
        case .cc: $draft.cc
        case .bcc: $draft.bcc
        default: nil
        }
    }

    /// The address being typed, in whichever address field has focus.
    private var typing: String {
        address(focus).map { Addresses.typing($0.wrappedValue) } ?? ""
    }

    private var canSend: Bool {
        !busy && uploading == 0 && ((try? draft.recipients.isEmpty) == false) && !(draft.encrypt == true && !missingKeys.isEmpty)
    }

    private var usesPGP: Bool { draft.encrypt == true || draft.sign == true }

    var body: some View {
        VStack(spacing: 0) {
            addressRow("To:", $draft.to, .to)
            Divider()
            addressRow("Cc:", $draft.cc, .cc)
            if showBcc {
                Divider()
                addressRow("Bcc:", $draft.bcc, .bcc)
            }
            Divider()
            row("Subject:") {
                TextField("Subject", text: $draft.subject)
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .focused($focus, equals: .subject)
            }
            if identities.count > 1 {
                Divider()
                row("From:") {
                    Picker("From", selection: $draft.identityId) {
                        ForEach(identities) { Text($0.address.formatted).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
            }
            notes
            Divider()
            FormatBar(state: format, editor: editor)
                .disabled(usesPGP)
            RichEditor(
                html: draft.html ?? Draft.html(fromText: draft.body), startFocused: !draft.to.isEmpty, controller: editor, state: $format,
                onChange: { draft.setHTML($0) }, onFiles: { attach(.success($0)) }
            )
            .id(editorVersion)
            if !draft.files.isEmpty || uploading > 0 {
                Divider()
                files
            }
            if let error {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        // Files dropped anywhere on the window are attached.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            attach(.success(files))
            return !files.isEmpty
        }
        .task(id: "\(String(describing: focus)) \(typing)") {
            try? await Task.sleep(for: .milliseconds(150))
            let text = typing
            let found = await store.suggestions(for: text, in: draft)
            guard !Task.isCancelled else { return }
            // Nothing to suggest once the whole address is there.
            suggestions = found.filter { $0.email.caseInsensitiveCompare(text) != .orderedSame && $0.formatted != text }
            suggestion = 0
        }
        .navigationTitle(draft.subject.isEmpty ? "New Message" : draft.subject)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    send(at: nil)
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Label("Send", systemImage: "paperplane.fill") }
                }
                .help("Send (⇧⌘D)")
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!canSend)
                Menu {
                    ForEach(SnoozeTime.choices(), id: \.title) { choice in
                        Button("Send \(choice.title)") { send(at: choice.date) }
                    }
                    Divider()
                    Button("Send Later…") { scheduling = true }
                } label: {
                    Label("Send Later", systemImage: "clock")
                }
                .help("Send Later")
                .disabled(!canSend)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if store.hasWren(draft) { wrenOptions }
                Button { picking = true } label: { Label("Attach", systemImage: "paperclip") }
                    .help("Attach Files (⇧⌘A)")
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button { discard() } label: { Label("Delete Draft", systemImage: "trash") }
                    .help("Delete Draft")
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { attach($0) }
        .sheet(isPresented: $scheduling) {
            ScheduleSheet(date: $sendAt) { send(at: sendAt) }
        }
        .disabled(busy)
        .onAppear {
            // A window opened or restored without a message to write starts a new one.
            if draft.accountId.isEmpty, let d = store.newDraft() {
                draft = d
                saved = d
                editorVersion += 1
            }
            if draft.to.isEmpty { focus = .to }
            if draft.encrypt == true { value = nil }
        }
        .task { await openEncryptedDraft() }
        .task(id: "\(draft.encrypt == true) \(draft.to) \(draft.cc) \(draft.bcc)") {
            guard draft.encrypt == true else { return missingKeys = [] }
            try? await Task.sleep(for: .milliseconds(400))
            let missing = await store.missingKeys(draft)
            if !Task.isCancelled { missingKeys = missing }
        }
        .confirmationDialog("Turn off encryption?", isPresented: $confirmingPlain) {
            Button("Send Unencrypted", role: .destructive) { draft.encrypt = false }
        } message: {
            Text("This message, including the text it quotes, will be saved and sent unencrypted.")
        }
        // Kept for restoring the window after Wren quits, which writes it to disk: never an Encrypt-on draft's plain text.
        .onChange(of: draft) { value = draft.encrypt == true ? nil : draft }
        // Another From address brings its own signature.
        .onChange(of: draft.identityId) { old, new in
            guard let old, let new, old != new else { return }
            let list = identities
            let before = Draft.signatureInner(list.first { $0.id == old })
            let after = Draft.signatureInner(list.first { $0.id == new })
            if before != after { editor.setSignature(after) }
        }
        .task {
            // Saved to Drafts every 30 seconds while there are changes, so a crash or a forced quit loses little.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if !Task.isCancelled { await autosave() }
            }
        }
        .onDisappear { saveOnClose() }
    }

    /// Private link, Encrypt and Sign: Wren's own options, for accounts on a server that has them.
    @ViewBuilder
    private var wrenOptions: some View {
        Menu {
            Picker("Send as Private Link", selection: $draft.privateLinkDays) {
                Text("Off").tag(Int?.none)
                ForEach([1, 7, 30], id: \.self) { Text($0 == 1 ? "For 1 Day" : "For \($0) Days").tag(Int?.some($0)) }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Private Link", systemImage: draft.privateLinkDays == nil ? "link" : "link.circle.fill")
        }
        .help(usesPGP ? "PGP mail can’t be sent as a private link" : "Send as a private link that stops working after a while")
        .disabled(usesPGP)
        Toggle(isOn: Binding(get: { draft.encrypt == true }, set: { on in
            if !on && saved.encrypt == true { confirmingPlain = true } else { setPGP(encrypt: on) }
        })) {
            Label("Encrypt", systemImage: draft.encrypt == true ? "lock.fill" : "lock.open")
        }
        .toggleStyle(.button)
        .help(draft.privateLinkDays != nil ? "Turn off the private link first: PGP mail can’t be sent as a link" : "Encrypt with PGP")
        .disabled(draft.privateLinkDays != nil)
        Toggle(isOn: Binding(get: { draft.sign == true }, set: { setPGP(sign: $0) })) {
            Label("Sign", systemImage: "signature")
        }
        .toggleStyle(.button)
        .help(draft.privateLinkDays != nil ? "Turn off the private link first: PGP mail can’t be sent as a link" : "Sign with your PGP key")
        .disabled(draft.privateLinkDays != nil)
    }

    /// Encrypt and Sign need your key on this Mac.
    private func setPGP(encrypt: Bool? = nil, sign: Bool? = nil) {
        Task {
            if encrypt == true || sign == true, let login = store.login(draft.login) ?? store.logins.first, await PGP.shared.key(login) == nil {
                error = "To encrypt or sign, restore your PGP key in Settings → Encryption."
                return
            }
            if let encrypt { draft.encrypt = encrypt }
            if let sign { draft.sign = sign }
            if error?.contains("PGP key in Settings") == true { error = nil }
        }
    }

    /// What the options do to this message, said plainly.
    @ViewBuilder
    private var notes: some View {
        if let days = draft.privateLinkDays {
            note("Sends as a private link that stops working after \(days == 1 ? "1 day" : "\(days) days").", "link")
        }
        if draft.encrypt == true {
            if missingKeys.isEmpty {
                note("Encrypted for everyone you’re writing to\(draft.sign == true ? " and signed" : ""), as plain text.", "lock.fill")
            } else {
                note("There’s no PGP key for \(missingKeys.joined(separator: ", ")). Remove them or turn off Encrypt.", "lock.trianglebadge.exclamationmark", .red)
            }
        } else if draft.sign == true {
            note("Signed with your PGP key, as plain text.", "signature")
        }
    }

    private func note(_ text: String, _ symbol: String, _ color: Color = .secondary) -> some View {
        VStack(spacing: 0) {
            Divider()
            Label(text, systemImage: symbol)
                .font(.callout)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }

    /// An encrypted draft opens decrypted, with Encrypt still on.
    private func openEncryptedDraft() async {
        guard draft.replaces != nil, let armored = PGPKind.armored(in: draft.body), let login = store.login(draft.login) ?? store.logins.first else { return }
        guard await PGP.shared.unlockAsking(login) else {
            error = "This draft is encrypted. Unlock your PGP key to edit it."
            return
        }
        do {
            let text = try await PGP.shared.decrypt(armored, login: login.id, senderKeys: []).text ?? ""
            draft.setHTML(Draft.html(fromText: text))
            draft.encrypt = true
            saved = draft
            editorVersion += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
                .accessibilityHidden(true)
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func addressRow(_ label: String, _ text: Binding<String>, _ field: Field) -> some View {
        // Checked once you leave the field, so typing isn't interrupted.
        let problem: String? = focus == field ? nil : {
            do {
                _ = try Addresses.parse(text.wrappedValue)
                return nil
            } catch {
                return error.localizedDescription
            }
        }()
        let suggesting = focus == field && !suggestions.isEmpty
        return row(label) {
            TextField(String(label.dropLast()), text: text)
                .textFieldStyle(.plain)
                .labelsHidden()
                .focused($focus, equals: field)
                .onKeyPress(.downArrow) { pick(suggestion + 1) }
                .onKeyPress(.upArrow) { pick(suggestion - 1) }
                .onKeyPress(.escape) {
                    guard suggesting else { return .ignored }
                    suggestions = []
                    return .handled
                }
                .onSubmit { if suggesting { accept(suggestions[min(suggestion, suggestions.count - 1)]) } }
            if let problem {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .help(problem)
                    .accessibilityLabel(problem)
            }
            if field == .cc && !showBcc {
                Button("Bcc") { showBcc = true; focus = .bcc }
                    .buttonStyle(.borderless)
                    .help("Add a Bcc field")
            }
        }
        // The suggestions hang below the field (lined up with it, past the label), over the rows after it.
        .overlay(alignment: .topLeading) {
            if suggesting {
                GeometryReader { row in
                    suggestionList.fixedSize(horizontal: false, vertical: true).offset(x: 80, y: row.size.height)
                }
            }
        }
        .zIndex(suggesting ? 1 : 0)
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { i, address in
                let on = i == suggestion
                Button { accept(address) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(address.displayName).lineLimit(1)
                        if address.name?.isEmpty == false {
                            Text(address.email).font(.caption).lineLimit(1).foregroundStyle(on ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                        }
                    }
                    .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(on ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(address.formatted)
            }
        }
        .padding(5)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    private func pick(_ index: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty, address(focus) != nil else { return .ignored }
        suggestion = (index + suggestions.count) % suggestions.count
        return .handled
    }

    private func accept(_ choice: EmailAddress) {
        guard let field = address(focus) else { return }
        field.wrappedValue = Addresses.complete(field.wrappedValue, with: choice)
        suggestions = []
    }

    private var files: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(draft.files, id: \.blobId) { file in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(for: UTType(mimeType: file.type) ?? .data))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(file.name).lineLimit(1)
                        Text(Int64(file.size).formatted(.byteCount(style: .file))).foregroundStyle(.secondary)
                        Button {
                            draft.files.removeAll { $0.blobId == file.blobId }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(file.name)")
                    }
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                }
                if uploading > 0 { ProgressView().controlSize(.small) }
            }
            .padding(10)
        }
    }

    private func attach(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        let target = draft
        for url in urls {
            uploading += 1
            Task {
                do {
                    draft.files.append(try await store.upload(url, for: target))
                } catch {
                    self.error = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
                uploading -= 1
            }
        }
    }

    private func send(at date: Date?) {
        do {
            guard try !draft.recipients.isEmpty else {
                error = "Add someone to send this to."
                return
            }
        } catch {
            self.error = error.localizedDescription
            return
        }
        busy = true
        error = nil
        Task {
            while copy.saving { try? await Task.sleep(for: .milliseconds(50)) }
            do {
                // With Encrypt or Sign on, what's saved and sent is the PGP text; nil if the passphrase was cancelled.
                guard var outgoing = try await store.sealed(draft, forSending: true) else {
                    busy = false
                    return
                }
                // Saved first, so a failed send leaves the message in Drafts instead of losing it.
                let id = try await store.save(outgoing)
                draft.replaces = id
                outgoing.replaces = id
                saved = draft
                try await store.send(outgoing, savedAs: id, at: date)
                done = true
                dismiss()
            } catch {
                self.error = error.localizedDescription + (draft.replaces == nil ? "" : " The message is in Drafts.")
            }
            busy = false
        }
    }

    private func discard() {
        done = true
        let d = draft
        Task { await store.discard(d) }
        dismiss()
    }

    private static func isBlank(_ d: Draft) -> Bool {
        [d.to, d.cc, d.bcc, d.subject, d.body].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } && d.files.isEmpty
    }

    /// Changes so far into Drafts, replacing the last copy. Not with Encrypt or Sign on: sealing can ask for the
    /// passphrase, which shouldn't pop up while you type; those are saved when the window closes.
    private func autosave() async {
        let d = draft
        guard !done, !busy, !copy.saving, uploading == 0, !usesPGP, d != saved, !Self.isBlank(d) else { return }
        copy.saving = true
        defer { copy.saving = false }
        guard let id = try? await store.save(d) else { return }
        copy.id = id
        guard !done else { return }
        // The next save replaces this one. What's typed meanwhile stays a change, for the next round.
        var kept = d
        kept.replaces = id
        saved = kept
        draft.replaces = id
    }

    private func saveOnClose() {
        let d = draft
        guard !done, d != saved, !Self.isBlank(d) else { return }
        let copy = copy
        Task {
            // A save still under way made a newer copy; this one replaces that.
            while copy.saving { try? await Task.sleep(for: .milliseconds(50)) }
            var d = d
            if let id = copy.id { d.replaces = id }
            do {
                // With Encrypt on, a draft is kept encrypted for you, never as plain text.
                guard let toSave = try await store.sealed(d, forSending: false) else { return }
                _ = try await store.save(toSave)
            } catch {
                store.alert = "Your draft couldn’t be saved: \(error.localizedDescription)"
            }
        }
    }
}

/// The newest copy of a message in Drafts, from saving in the background. A class, so a save that finishes after
/// the window has closed is still seen by the save on closing.
@MainActor
final class DraftCopy {
    var id: String?
    var saving = false
}

struct ScheduleSheet: View {
    @Binding var date: Date
    let schedule: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Send Later").font(.headline)
            DatePicker("Send at", selection: $date, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Schedule") {
                    dismiss()
                    schedule()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
