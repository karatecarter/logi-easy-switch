import Foundation
import CryptoKit

struct DeckSyncPacket {
    var suffix: String
    var payload: Data
}

struct DeckSyncManifest: Codable, Equatable {
    var schema = 3
    var source: String
    var group: String
    var snapshot: String
    var byteCount: Int
    var partCount: Int
}

enum DeckSyncTransfer {
    static let chunkSize = 48_000
    static let maximumSnapshot = 4 * 1024 * 1024
    static let maximumParts = (maximumSnapshot + chunkSize - 1) / chunkSize
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validHash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    static func packets(_ data: Data, source: String, group: String) throws -> (packets: [DeckSyncPacket], manifest: DeckSyncManifest?) {
        guard data.count <= maximumSnapshot else { throw DeckError.message("Shared configuration exceeds the 4 MB sync limit.") }
        if data.count <= DeckSyncEnvelope.maximumPayload { return ([DeckSyncPacket(suffix: "", payload: data)], nil) }
        let snapshot = hash(data)
        let count = (data.count + chunkSize - 1) / chunkSize
        let manifest = DeckSyncManifest(source: source, group: group, snapshot: snapshot, byteCount: data.count, partCount: count)
        var packets = (0..<count).map { index in
            DeckSyncPacket(suffix: "/chunks/\(snapshot)/\(index)", payload: data.subdata(in: (index * chunkSize)..<min((index + 1) * chunkSize, data.count)))
        }
        // Commit the manifest last. Retained delivery may still arrive in any order.
        packets.append(DeckSyncPacket(suffix: "", payload: try JSONEncoder().encode(manifest)))
        return (packets, manifest)
    }
    static func validate(_ manifest: DeckSyncManifest, peer: String, group: String) throws {
        guard manifest.schema == 3, manifest.source == peer, manifest.group == group,
              validHash(manifest.snapshot), manifest.byteCount > DeckSyncEnvelope.maximumPayload,
              manifest.byteCount <= maximumSnapshot, manifest.partCount > 0,
              manifest.partCount == (manifest.byteCount + chunkSize - 1) / chunkSize else {
            throw DeckError.message("Invalid shared snapshot manifest.")
        }
    }
}

struct DeckSyncAssembler {
    private struct Assembly {
        var manifest: DeckSyncManifest?
        var chunks: [Int: Data] = [:]
        var updated = Date()
    }
    private var assemblies: [String: Assembly] = [:]
    private var completed: Set<String> = []
    var pendingBytes: Int { assemblies.values.reduce(0) { $0 + $1.chunks.values.reduce(0) { $0 + $1.count } } }

    mutating func receive(_ data: Data, path: [String], peer: String, group: String, now: Date = Date()) throws -> Data? {
        assemblies = assemblies.filter { now.timeIntervalSince($0.value.updated) < 120 }
        let key: String
        if path.isEmpty {
            guard !data.isEmpty else { return nil }
            if let manifest = try? JSONDecoder().decode(DeckSyncManifest.self, from: data) {
                try DeckSyncTransfer.validate(manifest, peer: peer, group: group)
                key = peer + "/" + manifest.snapshot
                if completed.contains(key) { return nil }
                var assembly = assemblies[key] ?? Assembly()
                assembly.manifest = manifest
                assembly.updated = now
                assemblies[key] = assembly
            } else {
                guard data.count <= DeckSyncEnvelope.maximumPayload else { throw DeckError.message("Oversized MQTT snapshot packet.") }
                return data
            }
        } else {
            guard path.count == 3, path[0] == "chunks", DeckSyncTransfer.validHash(path[1]),
                  let index = Int(path[2]), index >= 0, index < DeckSyncTransfer.maximumParts,
                  data.count <= DeckSyncTransfer.chunkSize else { throw DeckError.message("Invalid shared snapshot chunk.") }
            key = peer + "/" + path[1]
            if completed.contains(key) || data.isEmpty { return nil }
            var assembly = assemblies[key] ?? Assembly()
            assembly.chunks[index] = data
            assembly.updated = now
            assemblies[key] = assembly
        }
        guard assemblies.count <= 128, pendingBytes <= DeckSyncTransfer.maximumSnapshot * 2 else {
            assemblies.removeAll()
            throw DeckError.message("Too many pending shared snapshot chunks. Reconnect to retry.")
        }
        guard let assembly = assemblies[key], let manifest = assembly.manifest,
              (0..<manifest.partCount).allSatisfy({ assembly.chunks[$0] != nil }) else { return nil }
        var combined = Data()
        for index in 0..<manifest.partCount { combined.append(assembly.chunks[index]!) }
        assemblies.removeValue(forKey: key)
        guard combined.count == manifest.byteCount, DeckSyncTransfer.hash(combined) == manifest.snapshot else {
            throw DeckError.message("Shared snapshot verification failed; shortcuts were not changed.")
        }
        completed.insert(key)
        if completed.count > 128 { completed = [key] }
        return combined
    }
}
