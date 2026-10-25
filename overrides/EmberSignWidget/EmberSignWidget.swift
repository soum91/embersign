import SwiftUI
import WidgetKit
import AppIntents
@main struct EmberSignWidgets: WidgetBundle {
    var body: some Widget {
        EmberExpiryWidget()
        if #available(iOS 18.0, *) { EmberActionControl() }
    }
}
struct EmberEntry: TimelineEntry { var date: Date; var state: EmberWidgetState }
struct EmberProvider: TimelineProvider {
    func placeholder(in context: Context) -> EmberEntry { .init(date: .now, state: .init()) }
    func getSnapshot(in context: Context, completion: @escaping (EmberEntry) -> Void) { completion(.init(date: .now, state: .load())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<EmberEntry>) -> Void) {
        completion(Timeline(entries: [.init(date: .now, state: .load())], policy: .after(.now.addingTimeInterval(3600))))
    }
}
struct EmberExpiryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EmberSignExpiry", provider: EmberProvider()) { entry in
            EmberExpiryView(entry: entry).containerBackground(for: .widget) { Color.clear }
        }.configurationDisplayName("Signing expiry").description("Nearest recorded signing expiry and apps due within three days. This does not verify installation or revocation.")
            .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
struct EmberExpiryView: View {
    @Environment(\.widgetFamily) var family
    var entry: EmberEntry
    var nearest: EmberAppEntity? { entry.state.apps.filter { $0.expiry != nil }.min { $0.expiry! < $1.expiry! } }
    var due: Int { entry.state.apps.filter { ($0.expiry ?? .distantFuture) <= entry.date.addingTimeInterval(3 * 86400) }.count }
    var body: some View {
        Group {
            if family == .accessoryInline { Text("EmberSign · \(due) expiring/expired") }
            else if family == .accessoryCircular {
                ZStack { AccessoryWidgetBackground(); VStack { Image(systemName: "signature"); Text("\(due)").font(.headline) } }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Label("EmberSign", systemImage: "flame.fill").font(.headline)
                    if let app = nearest, let expiry = app.expiry {
                        Text(app.name).font(.caption).lineLimit(1)
                        Text(expiry <= entry.date ? "Expired" : "Expires \(expiry.formatted(date: .abbreviated, time: .omitted))").font(.caption2)
                    } else { Text(entry.state.apps.isEmpty ? "Open EmberSign to load apps" : "No recorded expiry").font(.caption) }
                    Text("\(due) due/expired · \(entry.state.apps.count) signed").font(.caption2)
                }.privacySensitive()
            }
        }
    }
}
@available(iOS 18.0, *) struct EmberActionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "com.soum91.embersign.action", intent: EmberControlConfig.self) { config in
            ControlWidgetButton(action: OpenEmberIntent(config.action, app: config.app)) {
                Label(config.action == .jit ? (config.app?.name ?? "JIT tools") : config.action == .importIPA ? "Import IPA" : "Apps", systemImage: config.action == .jit ? "bolt.fill" : config.action == .importIPA ? "square.and.arrow.down" : "square.grid.2x2")
            }
        }.displayName("EmberSign action").description("Import an IPA, open Apps, or open the JIT workflow for a chosen app.")
    }
}
