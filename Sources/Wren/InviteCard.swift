import SwiftUI
import WrenKit

/// A calendar invitation in a message, as the web app's invite card shows it: what, when, where and who asks,
/// with Accept, Maybe and Decline (and a comment) sent to the organizer from Wren.
struct InviteCard: View {
    let email: Email
    let invite: Invite
    @Environment(MailStore.self) private var store
    @State private var comment = ""
    @State private var sending: Invite.Answer?
    /// The answer just sent, and who it went to, until the message is loaded again with it.
    @State private var sent: (answer: Invite.Answer, to: String?)?
    @State private var problem: String?

    private var answer: Invite.Answer? { sent?.answer ?? invite.answer }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: invite.isCancelled ? "calendar.badge.minus" : "calendar")
                    .font(.title2)
                    .foregroundStyle(invite.isCancelled ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(invite.summary.flatMap { $0.isEmpty ? nil : $0 } ?? "Invitation")
                        .font(.headline)
                    if invite.isCancelled {
                        Text("This event was canceled.").foregroundStyle(.red)
                    }
                    if let when = invite.when() { Label(when, systemImage: "clock") }
                    if let place = invite.location, !place.isEmpty { Label(place, systemImage: "mappin.and.ellipse") }
                    if let organizer = invite.organizer {
                        Label("Organized by \(organizer.name.flatMap { $0.isEmpty ? nil : $0 } ?? organizer.email)", systemImage: "person")
                            .help(organizer.email)
                    }
                    if let answer {
                        Label(answer.sentence + (sent?.to.map { " Wren let \($0) know." } ?? ""), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .font(.callout)
                .textSelection(.enabled)
            }
            // Only where it can be answered: not cancelled, sent by its organizer, and from an account that can send.
            if invite.canReply == true, !invite.isCancelled, store.canSendHere {
                HStack(spacing: 8) {
                    TextField("Add a comment (optional)", text: $comment)
                        .textFieldStyle(.roundedBorder)
                    ForEach(Invite.Answer.allCases, id: \.self) { choice in
                        let chosen = choice == answer
                        Button(choice.button) { reply(choice) }
                            .buttonStyle(.bordered)
                            .tint(chosen ? .accentColor : nil)
                            .fontWeight(chosen ? .semibold : .regular)
                            .accessibilityAddTraits(chosen ? .isSelected : [])
                            .help(chosen ? "Your answer" : "\(choice.button), and let the organizer know")
                    }
                    if sending != nil { ProgressView().controlSize(.small) }
                }
                .disabled(sending != nil)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Invitation")
    }

    private func reply(_ choice: Invite.Answer) {
        sending = choice
        problem = nil
        Task {
            do {
                let to = try await store.answer(email, choice, comment: comment)
                sent = (choice, to)
                comment = ""
            } catch {
                problem = error.localizedDescription
            }
            sending = nil
        }
    }
}
