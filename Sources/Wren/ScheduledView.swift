import SwiftUI
import WrenKit

/// Messages waiting to go out (Send Later, and ones still held for Undo Send), in every account. Each can be
/// stopped, which puts it back in Drafts, or opened to change and send again.
struct ScheduledView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var items: [(submission: Submission, login: String, account: String)] = []
    @State private var loaded = false
    @State private var working: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Scheduled Messages")
                .font(.headline)
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 8)
            Group {
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    ContentUnavailableView("No Scheduled Messages", systemImage: "clock", description: Text("Messages you send later wait here until they go."))
                } else {
                    List(items, id: \.submission.id) { item in
                        row(item)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minHeight: 220)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 380)
        .task { await load() }
    }

    private func row(_ item: (submission: Submission, login: String, account: String)) -> some View {
        let s = item.submission
        let to = s.to.map(\.displayName).joined(separator: ", ")
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text((s.subject ?? "").isEmpty ? "(No Subject)" : s.subject!).font(.body.weight(.semibold)).lineLimit(1)
                Text(to.isEmpty ? "No Recipients" : "To " + to).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if let at = s.sendAt {
                    Label(at.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if working == s.id {
                ProgressView().controlSize(.small)
            } else {
                Button("Edit") { cancel(item, edit: true) }
                    .help("Stop it and open it to change")
                Button("Don’t Send") { cancel(item, edit: false) }
                    .help("Stop it; it goes back to Drafts")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        items = await store.scheduled()
        loaded = true
    }

    private func cancel(_ item: (submission: Submission, login: String, account: String), edit: Bool) {
        working = item.submission.id
        error = nil
        Task {
            do {
                try await store.cancelScheduled(item.submission, login: item.login, account: item.account, edit: edit)
                if edit { dismiss() }
            } catch JMAPError.notSaved("cannotUnsend", _) {
                error = "That message has already been sent."
            } catch {
                self.error = error.localizedDescription
            }
            working = nil
            await load()
        }
    }
}
