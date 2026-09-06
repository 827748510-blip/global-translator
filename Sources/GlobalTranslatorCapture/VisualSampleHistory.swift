struct VisualSampleHistory {
    private var previous: [UInt16]?

    mutating func observe(_ samples: [UInt16]) -> Bool {
        guard let previous else {
            self.previous = samples
            return false
        }
        let changed = previous.count != samples.count ||
            zip(previous, samples).lazy.filter { $0 != $1 }.prefix(3).count >= 3
        if changed { self.previous = samples }
        return changed
    }

    mutating func reset() {
        previous = nil
    }
}
