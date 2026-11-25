struct VisualSampleHistory {
    private var previous: [UInt16]?

    mutating func observe(_ samples: [UInt16]) -> Bool {
        guard let previous else {
            self.previous = samples
            return false
        }
        guard previous.count == samples.count else {
            self.previous = samples
            return true
        }
        var diffCount = 0
        for index in 0..<samples.count where previous[index] != samples[index] {
            diffCount += 1
            if diffCount >= 3 {
                self.previous = samples
                return true
            }
        }
        return false
    }

    mutating func observeSwapping(_ samples: inout [UInt16]) -> Bool {
        guard var prev = self.previous else {
            self.previous = samples
            return false
        }
        self.previous = nil
        if prev.count != samples.count {
            swap(&prev, &samples)
            self.previous = prev
            return true
        }
        var diffCount = 0
        for index in 0..<samples.count where prev[index] != samples[index] {
            diffCount += 1
            if diffCount >= 3 {
                swap(&prev, &samples)
                self.previous = prev
                return true
            }
        }
        self.previous = prev
        return false
    }

    mutating func reset() {
        previous = nil
    }
}
