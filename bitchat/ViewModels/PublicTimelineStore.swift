//
// PublicTimelineStore.swift
// bitchat
//
// Maintains mesh and geohash public timelines with simple caps and helpers.
//

import BitFoundation
import Foundation

struct PublicTimelineStore {
    private var meshTimeline: [BitchatMessage] = []
    private var meshMessageIDs: Set<String> = []
    private var geohashTimelines: [String: [BitchatMessage]] = [:]
    private var geohashMessageIDs: [String: Set<String>] = [:]
    private var pendingGeohashSystemMessages: [String] = []

    private let meshCap: Int
    private let geohashCap: Int

    init(meshCap: Int, geohashCap: Int) {
        self.meshCap = meshCap
        self.geohashCap = geohashCap
    }

    mutating func append(_ message: BitchatMessage, to channel: ChannelID) {
        switch channel {
        case .mesh:
            guard !meshMessageIDs.contains(message.id) else { return }
            meshTimeline.append(message)
            meshMessageIDs.insert(message.id)
            trimMeshTimelineIfNeeded()
        case .location(let channel):
            append(message, toGeohash: channel.geohash)
        }
    }

    mutating func append(_ message: BitchatMessage, toGeohash geohash: String) {
        _ = appendGeohashMessageIfAbsent(message, geohash: geohash)
    }

    /// Append message if absent, returning true when stored.
    mutating func appendIfAbsent(_ message: BitchatMessage, toGeohash geohash: String) -> Bool {
        appendGeohashMessageIfAbsent(message, geohash: geohash)
    }

    mutating func messages(for channel: ChannelID) -> [BitchatMessage] {
        switch channel {
        case .mesh:
            return meshTimeline
        case .location(let channel):
            let cleaned = geohashTimelines[channel.geohash]?.cleanedAndDeduped() ?? []
            replaceGeohashTimeline(cleaned, for: channel.geohash, keepEmpty: true)
            return cleaned
        }
    }

    mutating func clear(channel: ChannelID) {
        switch channel {
        case .mesh:
            meshTimeline.removeAll()
            meshMessageIDs.removeAll()
        case .location(let channel):
            geohashTimelines[channel.geohash] = []
            geohashMessageIDs[channel.geohash] = []
        }
    }

    @discardableResult
    mutating func removeMessage(withID id: String) -> BitchatMessage? {
        if let index = meshTimeline.firstIndex(where: { $0.id == id }) {
            let removed = meshTimeline.remove(at: index)
            meshMessageIDs.remove(id)
            return removed
        }

        for key in Array(geohashTimelines.keys) {
            var timeline = geohashTimelines[key] ?? []
            if let index = timeline.firstIndex(where: { $0.id == id }) {
                let removed = timeline.remove(at: index)
                replaceGeohashTimeline(timeline, for: key, keepEmpty: false)
                return removed
            }
        }

        return nil
    }

    mutating func removeMessages(in geohash: String, where predicate: (BitchatMessage) -> Bool) {
        var timeline = geohashTimelines[geohash] ?? []
        timeline.removeAll(where: predicate)
        replaceGeohashTimeline(timeline, for: geohash, keepEmpty: false)
    }

    mutating func mutateGeohash(_ geohash: String, _ transform: (inout [BitchatMessage]) -> Void) {
        var timeline = geohashTimelines[geohash] ?? []
        transform(&timeline)
        replaceGeohashTimeline(timeline, for: geohash, keepEmpty: false)
    }

    mutating func queueGeohashSystemMessage(_ content: String) {
        pendingGeohashSystemMessages.append(content)
    }

    mutating func drainPendingGeohashSystemMessages() -> [String] {
        defer { pendingGeohashSystemMessages.removeAll(keepingCapacity: false) }
        return pendingGeohashSystemMessages
    }

    func geohashKeys() -> [String] {
        Array(geohashTimelines.keys)
    }

    private mutating func trimMeshTimelineIfNeeded() {
        guard meshTimeline.count > meshCap else { return }
        meshTimeline = Array(meshTimeline.suffix(meshCap))
        meshMessageIDs = Set(meshTimeline.map(\.id))
    }

    private mutating func appendGeohashMessageIfAbsent(_ message: BitchatMessage, geohash: String) -> Bool {
        var timeline = geohashTimelines[geohash] ?? []
        var messageIDs = geohashMessageIDs[geohash] ?? Set(timeline.map(\.id))
        guard messageIDs.insert(message.id).inserted else { return false }

        timeline.append(message)
        trimGeohashTimelineIfNeeded(&timeline, messageIDs: &messageIDs)
        geohashTimelines[geohash] = timeline
        geohashMessageIDs[geohash] = messageIDs
        return true
    }

    private func trimGeohashTimelineIfNeeded(_ timeline: inout [BitchatMessage], messageIDs: inout Set<String>) {
        guard timeline.count > geohashCap else { return }
        timeline = Array(timeline.suffix(geohashCap))
        messageIDs = Set(timeline.map(\.id))
    }

    private mutating func replaceGeohashTimeline(_ timeline: [BitchatMessage], for geohash: String, keepEmpty: Bool) {
        if timeline.isEmpty && !keepEmpty {
            geohashTimelines[geohash] = nil
            geohashMessageIDs[geohash] = nil
            return
        }

        geohashTimelines[geohash] = timeline
        geohashMessageIDs[geohash] = Set(timeline.map(\.id))
    }
}
