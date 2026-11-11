import SwiftUI
import WrenKit

/// The first sign-in fills the window; another one (Settings → Accounts) comes up in a sheet, with `done`.
struct SignInView: View {
    var done: (() -> Void)?
    @Environment(MailStore.self) private var store
    @AppStorage("server") private var server = ""
    @AppStorage("username") private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    private var ready: Bool { !server.isEmpty && !username.isEmpty && !password.isEmpty && !busy }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bird.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(done == nil ? "Sign in to Wren" : "Add a Wren Account")
                .font(.title.weight(.semibold))
            Text("Use an app password, not your account password. Create one in Wren on the web, under Settings → Security → Mail apps.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Form {
                TextField("Server", text: $server, prompt: Text("mail.example.com"))
                TextField("Email", text: $username, prompt: Text("you@example.com"))
                    .textContentType(.username)
                SecureField("App password", text: $password)
                    .textContentType(.password)
            }
            .formStyle(.grouped)
            .frame(width: 420)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(busy)
            .onSubmit { if ready { signIn() } }

            if let message = error ?? (done == nil ? store.signInMessage : nil) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: 400)
                    .multilineTextAlignment(.center)
            }

            HStack {
                if let done {
                    Button("Cancel", action: done)
                        .controlSize(.large)
                        .keyboardShortcut(.cancelAction)
                }
                Button {
                    signIn()
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("Sign In") }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!ready)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Another account is usually another address on the same server.
        .onAppear { if done != nil { username = "" } }
    }

    private func signIn() {
        guard let url = ServerAddress.url(from: server) else {
            error = "Enter your Wren server’s address, such as mail.example.com. It has to use https."
            return
        }
        error = nil
        busy = true
        Task {
            do {
                try await store.signIn(server: url, username: username.trimmingCharacters(in: .whitespaces).lowercased(), password: password.trimmingCharacters(in: .whitespacesAndNewlines))
                password = ""
                done?()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
