import Foundation
#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif

/// Sends feature keys to the backend, built for one publishable key.
internal protocol FeatureCheckSender: Sendable {
    func send(keys: [String]) async throws
}

/// Production sender: the same Backend `configure` builds for the new key.
internal struct BackendFeatureCheckSender: FeatureCheckSender {
    let backend: Backend
    func send(keys: [String]) async throws {
        try await backend.reportFeaturesChecked(keys: keys)
    }
}

/// Reports the feature keys the app checks through `hasAccess` and `value`, so the dashboard's
/// "Check it in your app" step can complete. Each key goes out once per process per configured
/// publishable key. It never blocks or throws to the caller; the network runs in a `Task` off the
/// main actor. Failures leave keys pending with a backoff.
@MainActor
internal final class FeatureCheckReporter {
    static let maxKeysPerRequest = 50
    static let maxKeyLength = 64

    private let delay: TimeInterval
    private let backoff: TimeInterval
    private let now: () -> Date

    private var sender: FeatureCheckSender?
    private var generation = 0
    private var sent = Set<String>()
    private var pending: [String] = []
    private var pendingSet = Set<String>()
    private var flushScheduled = false
    private var flushTask: Task<Void, Never>?
    private var backoffUntil: Date?

    init(delay: TimeInterval = 2, backoff: TimeInterval = 60, now: @escaping () -> Date = Date.init) {
        self.delay = delay
        self.backoff = backoff
        self.now = now
    }

    /// Record that the app checked a key. Dropped before the first `reset(sender:)`.
    func note(_ key: String) {
        guard sender != nil else { return }
        let length = key.unicodeScalars.count
        guard length > 0, length <= Self.maxKeyLength else { return }
        guard !sent.contains(key) else { return }
        if pendingSet.insert(key).inserted { pending.append(key) }
        scheduleFlush()
    }

    /// Start over for a new publishable key or API base URL.
    func reset(sender: FeatureCheckSender) {
        generation += 1
        flushTask?.cancel()
        flushTask = nil
        flushScheduled = false
        sent.removeAll()
        pending.removeAll()
        pendingSet.removeAll()
        backoffUntil = nil
        self.sender = sender
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        if let backoffUntil, now() < backoffUntil { return }
        flushScheduled = true
        let gen = generation
        flushTask = Task { [weak self] in
            await self?.runFlush(generation: gen)
        }
    }

    private func runFlush(generation gen: Int) async {
        var failed = false
        defer {
            if gen == generation {
                flushScheduled = false
                flushTask = nil
                if !failed && !pending.isEmpty { scheduleFlush() }
            }
        }
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        // Capture the sender in the same main-actor step that checks the generation.
        guard gen == generation, !Task.isCancelled, let sender else { return }
        while gen == generation, !Task.isCancelled {
            let batch = Array(pending.prefix(Self.maxKeysPerRequest))
            if batch.isEmpty { return }
            do {
                try await sender.send(keys: batch)
                guard gen == generation else { return }
                markSent(batch)
            } catch {
                guard gen == generation else { return }
                if Self.isFinalRejection(error) {
                    markSent(batch)
                } else {
                    failed = true
                    backoffUntil = now().addingTimeInterval(backoff)
                    ZSLogger.debug("[FeatureCheck] report failed: \(error)", category: .general)
                    return
                }
            }
        }
    }

    private func markSent(_ batch: [String]) {
        pending.removeFirst(batch.count)
        for key in batch {
            pendingSet.remove(key)
            sent.insert(key)
        }
    }

    /// 400, 401 and 403 cannot succeed on retry.
    private static func isFinalRejection(_ error: Error) -> Bool {
        guard case .apiError(let detail) = error as? ZeroSettleError, let status = detail.statusCode else { return false }
        return status == 400 || status == 401 || status == 403
    }

    #if DEBUG
    var generationForTesting: Int { generation }

    /// Wait for the scheduled or running flush, and any it chains, to finish.
    func waitForIdleForTesting() async {
        while let task = flushTask { await task.value }
    }
    #endif
}
