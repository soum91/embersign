import Foundation
import AppIntents

struct EmberAppEntity: AppEntity, Codable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Signed app"
    static var defaultQuery = EmberAppQuery()
    var id: String
    var name: String
    var expiry: Date?
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)", subtitle: "\(id)") }
}
struct EmberAppQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [EmberAppEntity] { EmberWidgetState.load().apps.filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [EmberAppEntity] { EmberWidgetState.load().apps }
}
struct EmberWidgetState: Codable {
    var apps: [EmberAppEntity] = []
    var updatedAt: Date = .distantPast
    static func load() -> Self { AppGroup.read(Self.self, "ember-widget.json") ?? Self() }
}
enum EmberQuickAction: String, AppEnum {
    case importIPA, library, jit
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "EmberSign action"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.importIPA: "Import IPA", .library: "App library", .jit: "JIT tools"]
}
@available(iOS 18.0, *) struct EmberControlConfig: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "EmberSign action"
    @Parameter(title: "Action", default: .library) var action: EmberQuickAction
    @Parameter(title: "App for JIT") var app: EmberAppEntity?
}
struct OpenEmberIntent: AppIntent {
    static var title: LocalizedStringResource = "Open EmberSign Action"
    static var openAppWhenRun = true
    @Parameter(title: "Action") var action: EmberQuickAction
    @Parameter(title: "App") var app: EmberAppEntity?
    init() { action = .library }
    init(_ action: EmberQuickAction, app: EmberAppEntity? = nil) { self.action = action; self.app = app }
    @MainActor func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        if action == .jit { EmberJITService.shared.present(bundleID: app?.id ?? "") }
        else { EmberQuickRouter.shared.destination = action == .importIPA ? .importIPA : .library }
        #endif
        return .result()
    }
}
