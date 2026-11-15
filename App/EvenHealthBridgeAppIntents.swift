import AppIntents
import Observation

enum EvenHealthBridgeDestination: Equatable, Sendable {
    case importArchive
    case appleWatchStudy

    var tabIndex: Int {
        switch self {
        case .importArchive: 0
        case .appleWatchStudy: 1
        }
    }
}

struct EvenHealthBridgeIntentRoute: Equatable, Sendable {
    let id = UUID()
    let destination: EvenHealthBridgeDestination
}

/// One local handoff point for system actions that need to open a specific app workflow.
@MainActor @Observable
final class EvenHealthBridgeIntentRouter {
    static let shared = EvenHealthBridgeIntentRouter()

    var pendingRoute: EvenHealthBridgeIntentRoute?

    private init() {}

    func open(_ destination: EvenHealthBridgeDestination) {
        pendingRoute = EvenHealthBridgeIntentRoute(destination: destination)
    }
}

struct ImportEvenDataIntent: AppIntent {
    static let targetDestination = EvenHealthBridgeDestination.importArchive
    static let title: LocalizedStringResource = "Importa dati Even"
    static let description = IntentDescription("Apri l'app per selezionare un archivio ZIP Even.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await EvenHealthBridgeIntentRouter.shared.open(Self.targetDestination)
        return .result()
    }
}

struct StudyEvenDataIntent: AppIntent {
    static let targetDestination = EvenHealthBridgeDestination.appleWatchStudy
    static let title: LocalizedStringResource = "Analizza dati Even"
    static let description = IntentDescription("Apri lo studio locale dei dati Even e Apple Watch.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await EvenHealthBridgeIntentRouter.shared.open(Self.targetDestination)
        return .result()
    }
}

struct EvenHealthBridgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ImportEvenDataIntent(),
            phrases: [
                "Importa dati Even in \(.applicationName)",
                "Apri importazione in \(.applicationName)"
            ],
            shortTitle: "Importa dati",
            systemImageName: "doc.zipper"
        )
        AppShortcut(
            intent: StudyEvenDataIntent(),
            phrases: [
                "Analizza dati Even in \(.applicationName)",
                "Apri studio in \(.applicationName)"
            ],
            shortTitle: "Analizza dati",
            systemImageName: "applewatch"
        )
    }
}
