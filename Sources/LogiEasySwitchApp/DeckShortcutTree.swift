import Foundation

enum DeckShortcutTree {
    static func isContainer(_ button: DeckButton) -> Bool { ["folder", "group"].contains(button.kind) }
    static func canMove(_ id: UUID, to parent: UUID?, buttons: [DeckButton]) -> Bool {
        guard let source = buttons.first(where: { $0.id == id }) else { return false }
        if let parent {
            guard let destination = buttons.first(where: { $0.id == parent }), isContainer(destination),
                  !(source.kind == "group" && destination.kind == "group") else { return false }
        }
        var ancestor = parent
        var visited: Set<UUID> = []
        while let current = ancestor {
            guard current != id, visited.insert(current).inserted else { return false }
            ancestor = buttons.first { $0.id == current }?.parentID
        }
        return true
    }
    static func moving(_ id: UUID, to parent: UUID?, at index: Int, buttons: [DeckButton]) -> [DeckButton]? {
        guard canMove(id, to: parent, buttons: buttons), let sourceIndex = buttons.firstIndex(where: { $0.id == id }) else { return nil }
        let oldSiblings = buttons.filter { $0.parentID == parent }.map(\.id)
        let oldPosition = oldSiblings.firstIndex(of: id)
        var siblings = oldSiblings.filter { $0 != id }
        let adjusted = index - ((oldPosition.map { $0 < index } ?? false) ? 1 : 0)
        siblings.insert(id, at: min(siblings.count, max(0, adjusted)))
        var updated = buttons
        updated[sourceIndex].parentID = parent
        var result: [DeckButton] = []
        var visited: Set<UUID> = []
        func appendChildren(_ owner: UUID?) {
            let children: [DeckButton]
            if owner == parent {
                children = siblings.compactMap { child in updated.first { $0.id == child } }
            } else { children = updated.filter { $0.parentID == owner } }
            for button in children where visited.insert(button.id).inserted {
                result.append(button)
                appendChildren(button.id)
            }
        }
        appendChildren(nil)
        // Preserve malformed/orphaned records rather than losing user data.
        result.append(contentsOf: updated.filter { !visited.contains($0.id) })
        return result
    }
}
