import Foundation

enum DeckSyncScope {
    /// A local folder/group also keeps its descendants local so remote Macs
    /// cannot receive controls whose owner does not exist there.
    static func isShared(_ button: DeckButton, in configuration: DeckConfiguration) -> Bool {
        var current: DeckButton? = button
        var visited: Set<UUID> = []
        while let candidate = current {
            guard visited.insert(candidate.id).inserted else { return true } // Invalid cycles are rejected by configuration validation.
            if candidate.syncWithGroup == false { return false }
            current = candidate.parentID.flatMap { parent in configuration.buttons.first { $0.id == parent } }
        }
        return true
    }
}
