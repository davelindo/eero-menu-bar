import Foundation

enum PollMode: Sendable {
    case foreground
    case background
}

final class PollingCoordinator {
    var onTick: (@Sendable () async -> Void)?

    private var task: Task<Void, Never>?
    private var mode: PollMode = .background
    private var foregroundInterval: TimeInterval
    private var backgroundInterval: TimeInterval

    init(foregroundInterval: TimeInterval, backgroundInterval: TimeInterval) {
        self.foregroundInterval = foregroundInterval
        self.backgroundInterval = backgroundInterval
    }

    func updateIntervals(foreground: TimeInterval, background: TimeInterval) {
        foregroundInterval = max(3, foreground)
        backgroundInterval = max(15, background)
    }

    func setMode(_ mode: PollMode) {
        self.mode = mode
    }

    func start() {
        guard task == nil else { return }
        task = Task {
            await onTick?()
            while !Task.isCancelled {
                let seconds = mode == .foreground ? foregroundInterval : backgroundInterval
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if Task.isCancelled { break }
                await onTick?()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func triggerNow() {
        Task {
            await onTick?()
        }
    }
}
