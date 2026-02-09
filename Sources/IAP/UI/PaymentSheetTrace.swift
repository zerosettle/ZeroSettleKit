//
//  PaymentSheetTrace.swift
//  ZeroSettleIAP
//
//  Hierarchical performance tracer for ZSPaymentSheet operations.
//  Records spans and instant events, then prints a flamegraph-style
//  tree showing where time is spent.
//

import Foundation
import os

// MARK: - Trace

/// Hierarchical performance tracer for payment sheet operations.
///
/// Records nested spans with timing and metadata, then outputs a
/// tree-formatted flamegraph when the trace completes.
///
///     let trace = PaymentSheetTrace("preloadAll")
///     let span = trace.begin("cache.check")
///     // ... work ...
///     trace.end(span, metadata: ["result": "MISS"])
///     trace.finish() // prints flamegraph
///
internal final class PaymentSheetTrace: @unchecked Sendable {

    /// The currently active trace. Set before preloading begins.
    static var current: PaymentSheetTrace?

    static let logger = Logger(subsystem: "com.zerosettle.iap", category: "PaymentSheet")

    typealias SpanID = UUID

    // MARK: - Internal Types

    private final class SpanNode {
        let id: SpanID
        let label: String
        let startTime: CFAbsoluteTime
        var endTime: CFAbsoluteTime?
        var metadata: [String: String]
        weak var parent: SpanNode?
        var children: [SpanNode] = []
        var events: [InstantEvent] = []

        var durationMs: Double? {
            guard let end = endTime else { return nil }
            return (end - startTime) * 1000
        }

        var formattedDuration: String {
            guard let ms = durationMs else { return "..." }
            if ms < 1 { return "<1ms" }
            return String(format: "%.0fms", ms)
        }

        init(id: SpanID, label: String, startTime: CFAbsoluteTime, metadata: [String: String] = [:]) {
            self.id = id
            self.label = label
            self.startTime = startTime
            self.metadata = metadata
        }
    }

    private struct InstantEvent {
        let label: String
        let timestamp: CFAbsoluteTime
        let metadata: [String: String]
    }

    // MARK: - State

    private let root: SpanNode
    private var nodes: [SpanID: SpanNode] = [:]
    private var spanStack: [SpanID] = []
    private let lock = NSLock()

    // MARK: - Init

    init(_ label: String) {
        let node = SpanNode(id: UUID(), label: label, startTime: CFAbsoluteTimeGetCurrent())
        self.root = node
        self.nodes[node.id] = node
        self.spanStack = [node.id]
        Self.logger.debug("⏱ [\(label)] trace started")
    }

    // MARK: - Recording

    /// Begin a new span. Returns a SpanID to pass to `end()`.
    @discardableResult
    func begin(_ label: String, metadata: [String: String] = [:]) -> SpanID {
        lock.lock()
        defer { lock.unlock() }

        let node = SpanNode(id: UUID(), label: label, startTime: CFAbsoluteTimeGetCurrent(), metadata: metadata)
        nodes[node.id] = node

        // Attach to current parent
        if let parentId = spanStack.last, let parent = nodes[parentId] {
            node.parent = parent
            parent.children.append(node)
        }

        spanStack.append(node.id)

        let meta = Self.formatMeta(metadata)
        Self.logger.debug("⏱  ▶ \(label)\(meta)")
        return node.id
    }

    /// End a span, optionally adding metadata.
    func end(_ id: SpanID, metadata: [String: String] = [:]) {
        lock.lock()
        defer { lock.unlock() }

        guard let node = nodes[id] else { return }
        node.endTime = CFAbsoluteTimeGetCurrent()
        for (k, v) in metadata { node.metadata[k] = v }

        // Pop from stack
        if let idx = spanStack.lastIndex(of: id) {
            spanStack.remove(at: idx)
        }

        let meta = Self.formatMeta(metadata)
        Self.logger.debug("⏱  ◀ \(node.label): \(node.formattedDuration)\(meta)")
    }

    /// Record a point-in-time event within the current span.
    func event(_ label: String, metadata: [String: String] = [:]) {
        lock.lock()
        let evt = InstantEvent(label: label, timestamp: CFAbsoluteTimeGetCurrent(), metadata: metadata)
        if let parentId = spanStack.last, let parent = nodes[parentId] {
            parent.events.append(evt)
        }
        lock.unlock()

        let meta = Self.formatMeta(metadata)
        Self.logger.debug("⏱  ● \(label)\(meta)")
    }

    /// Complete the trace and print the flamegraph.
    func finish() {
        lock.lock()
        root.endTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()

        let output = buildFlamegraph()
        Self.logger.info("\n\(output)")
        Self.current = nil
    }

    // MARK: - Flamegraph Output

    private func buildFlamegraph() -> String {
        let totalMs = root.formattedDuration
        let divider = String(repeating: "─", count: 54)

        var lines: [String] = []
        lines.append("┌\(divider)")
        lines.append("│ ZSPaymentSheet Trace — \(totalMs)")
        lines.append("├\(divider)")

        renderNode(root, prefix: "│ ", isRoot: true, lines: &lines)

        lines.append("└\(divider)")
        return lines.joined(separator: "\n")
    }

    private func renderNode(_ node: SpanNode, prefix: String, isRoot: Bool, lines: inout [String]) {
        // Merge children and events into a single sorted timeline
        var timeline: [(time: CFAbsoluteTime, kind: TimelineItem)] = []

        for child in node.children {
            timeline.append((child.startTime, .span(child)))
        }
        for evt in node.events {
            timeline.append((evt.timestamp, .event(evt)))
        }
        timeline.sort { $0.time < $1.time }

        for (i, entry) in timeline.enumerated() {
            let isLast = i == timeline.count - 1
            let connector = isLast ? "└─" : "├─"
            let childPrefix = prefix + (isLast ? "   " : "│  ")

            switch entry.kind {
            case .span(let child):
                let meta = Self.formatMeta(child.metadata)
                let dots = Self.dots(for: child.label, width: 44)
                lines.append("\(prefix)\(connector) \(child.label) \(dots) \(child.formattedDuration)\(meta)")
                renderNode(child, prefix: childPrefix, isRoot: false, lines: &lines)

            case .event(let evt):
                let offsetMs = (evt.timestamp - root.startTime) * 1000
                let meta = Self.formatMeta(evt.metadata)
                lines.append("\(prefix)\(connector) \(evt.label)\(meta) · +\(String(format: "%.0fms", offsetMs))")
            }
        }
    }

    private enum TimelineItem {
        case span(SpanNode)
        case event(InstantEvent)
    }

    // MARK: - Formatting Helpers

    private static func formatMeta(_ meta: [String: String]) -> String {
        guard !meta.isEmpty else { return "" }
        let pairs = meta.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }
        return " [\(pairs.joined(separator: ", "))]"
    }

    private static func dots(for label: String, width: Int) -> String {
        let needed = max(2, width - label.count)
        return String(repeating: "·", count: needed)
    }
}
