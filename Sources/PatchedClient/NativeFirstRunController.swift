import Combine
import PatchedShell

/// First-run setup: three explanatory steps. Finishing records only that setup was completed,
/// so setup appears on a fresh install and not after it has been finished once.
@MainActor public final class NativeFirstRunController: ObservableObject {
    public enum Step: Equatable, Sendable { case welcome, review, findApps }
    public let navigation: ShellNavigation
    private let completion: any SetupCompletionStoring
    @Published public private(set) var step: Step = .welcome
    @Published public private(set) var isPresented: Bool

    public convenience init(navigation: ShellNavigation) {
        self.init(navigation: navigation, completion: DefaultsSetupCompletion())
    }
    public init(navigation: ShellNavigation, completion: any SetupCompletionStoring) {
        self.navigation = navigation
        self.completion = completion
        isPresented = !completion.completed
    }
    public var setupCompleted: Bool { completion.completed }

    public func advance() {
        guard isPresented else { return }
        switch step {
        case .welcome: step = .review
        case .review: step = .findApps
        case .findApps: openUpdates()
        }
    }
    public func back() {
        switch step {
        case .welcome: break
        case .review: step = .welcome
        case .findApps: step = .review
        }
    }
    /// The last step's action: records completion and shows Updates.
    public func openUpdates() {
        guard isPresented else { return }
        completion.markCompleted()
        isPresented = false
        navigation.select(.updates)
    }
    public func present() { isPresented = true }
    public func dismiss() { isPresented = false }
}
