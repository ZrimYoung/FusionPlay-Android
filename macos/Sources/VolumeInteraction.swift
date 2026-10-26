import Foundation

// UI draft and receiver feedback have different ownership while a gesture or
// submission is in flight. Both windows share this state through ReceiverModel.
struct VolumeInteraction {
    private struct Pending {
        let token: UInt64
        let value: Double
        var acknowledged: Bool
        var completed = false
    }
    private(set) var value = 50.0
    private(set) var isEditing = false
    private var remote = 50.0
    private var nextToken: UInt64 = 0
    private var pending: Pending?

    mutating func edit(_ value: Double) { self.value = min(max(value, 0), 100) }
    mutating func beginEditing() { isEditing = true }
    mutating func observe(_ value: Double) {
        remote = min(max(value, 0), 100)
        if pending?.value == remote { pending?.acknowledged = true }
        if pending?.completed == true && pending?.acknowledged == true { pending = nil }
        if !isEditing && pending == nil { self.value = remote }
    }
    mutating func submit() -> (token: UInt64, value: UInt32) {
        isEditing = false
        value = value.rounded()
        nextToken += 1
        pending = Pending(token: nextToken, value: value, acknowledged: remote == value)
        return (nextToken, UInt32(value))
    }
    @discardableResult
    mutating func complete(_ token: UInt64, succeeded: Bool) -> Bool {
        guard pending?.token == token else { return false }
        if succeeded {
            pending?.completed = true
            if pending?.acknowledged == true { pending = nil }
        } else {
            pending = nil
            if !isEditing { value = remote }
        }
        return true
    }
    // A lost event must not lock the slider forever. Subsequent receiver updates
    // remain authoritative; a new gesture is never replaced by this timeout.
    mutating func expire(_ token: UInt64) {
        guard pending?.token == token, pending?.completed == true else { return }
        pending = nil
        if !isEditing { value = remote }
    }
}
