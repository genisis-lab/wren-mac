import SwiftUI
import WidgetKit

@main
struct WrenWidgets: WidgetBundle {
    var body: some Widget { UnreadWidget() }
}

/// Unread mail in each Inbox, for the desktop and Notification Center. Wren reloads it when the counts change.
struct UnreadWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Unread", provider: Provider()) { UnreadView(entry: $0) }
            .configurationDisplayName("Unread Mail")
            .description("How much unread mail is in each of your Inboxes.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct UnreadEntry: TimelineEntry {
    var date = Date.now
    var mail: UnreadMail?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> UnreadEntry {
        UnreadEntry(mail: UnreadMail(inboxes: [.init(name: "Inbox", unread: 3)]))
    }

    func getSnapshot(in context: Context, completion: @escaping (UnreadEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : UnreadEntry(mail: UnreadMail.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UnreadEntry>) -> Void) {
        completion(Timeline(entries: [UnreadEntry(mail: UnreadMail.load())], policy: .never))
    }
}

struct UnreadView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UnreadEntry

    var body: some View {
        Group {
            if let mail = entry.mail, !mail.inboxes.isEmpty {
                if family == .systemSmall { small(mail) } else { medium(mail) }
            } else {
                Label("Open Wren to see your unread mail here.", systemImage: "tray")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func small(_ mail: UnreadMail) -> some View {
        VStack(alignment: .leading) {
            Label("Unread", systemImage: "tray")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(mail.total, format: .number)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.5)
            Text(mail.inboxes.count == 1 ? mail.inboxes[0].name : "\(mail.inboxes.count) Inboxes")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(mail.total) unread")
    }

    private func medium(_ mail: UnreadMail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Unread", systemImage: "tray")
                Spacer()
                Text(mail.total, format: .number).monospacedDigit()
            }
            .font(.headline)
            Divider()
            ForEach(Array(mail.inboxes.prefix(4).enumerated()), id: \.offset) { _, inbox in
                HStack {
                    Text(inbox.name).lineLimit(1)
                    Spacer()
                    Text(inbox.unread, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(inbox.unread > 0 ? .primary : .secondary)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
        }
    }
}
