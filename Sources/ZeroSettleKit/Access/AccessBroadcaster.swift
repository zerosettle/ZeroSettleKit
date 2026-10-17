//
//  AccessBroadcaster.swift
//  ZeroSettleKit
//
//  Fans each access change out to every `accessUpdates` listener. A new
//  listener first receives the current value.
//

import Foundation

@MainActor
final class AccessBroadcaster {
    private var continuations: [UUID: AsyncStream<ZSAccess>.Continuation] = [:]

    var listenerCount: Int { continuations.count }

    func stream(current: ZSAccess) -> AsyncStream<ZSAccess> {
        let (stream, continuation) = AsyncStream.makeStream(of: ZSAccess.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations[id] = nil }
        }
        continuation.yield(current)
        return stream
    }

    func yield(_ access: ZSAccess) {
        for continuation in continuations.values {
            continuation.yield(access)
        }
    }
}
