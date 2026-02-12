import Foundation

actor ActionExecutor {
    private let apiClient: EeroAPIClientProtocol
    private let queue: PendingActionQueue

    init(apiClient: EeroAPIClientProtocol, queue: PendingActionQueue) {
        self.apiClient = apiClient
        self.queue = queue
    }

    func execute(_ action: EeroAction, cloudReachable: Bool) async -> ActionExecutionResult {
        if !cloudReachable {
            guard action.queueEligible else {
                return .rejected(message: "This action is not allowed while cloud access is unavailable.")
            }
            await queue.enqueue(action)
            return .queued
        }

        do {
            try await apiClient.perform(action)
            return .success
        } catch {
            if shouldQueueActionAfterFailure(action: action, error: error) {
                await queue.enqueue(action)
                return .queued
            }
            return .failed(message: error.localizedDescription)
        }
    }

    func replayQueuedActions() async {
        let items = await queue.all().filter { $0.status == .pending || $0.status == .failed }
        for item in items {
            do {
                try await apiClient.perform(item.action)
                await queue.mark(id: item.id, status: .replayed, error: nil)
            } catch {
                await queue.mark(id: item.id, status: .failed, error: error.localizedDescription)
            }
        }
        await queue.clearReplayed()
    }

    func queuedActions() async -> [QueuedAction] {
        await queue.all()
    }

    func removeQueuedAction(id: UUID) async {
        await queue.remove(id: id)
    }

    private func shouldQueueActionAfterFailure(action: EeroAction, error: Error) -> Bool {
        guard action.queueEligible else {
            return false
        }

        if let apiError = error as? EeroAPIError {
            switch apiError {
            case .server(let code, _):
                return [408, 429, 500, 502, 503, 504].contains(code)
            case .unauthenticated, .invalidPayload, .invalidResponse:
                return false
            }
        }

        if let urlError = error as? URLError {
            return transientURLErrorCodes.contains(urlError.code)
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            return transientURLErrorCodes.contains(code)
        }

        return false
    }

    private var transientURLErrorCodes: Set<URLError.Code> {
        [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .networkConnectionLost,
            .notConnectedToInternet,
            .resourceUnavailable,
            .cannotLoadFromNetwork
        ]
    }
}
