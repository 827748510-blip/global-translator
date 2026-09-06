import Testing
@testable import GlobalTranslatorCapture

struct VisualSampleHistoryTests {
    @Test
    func firstFrameEstablishesBaselineWithoutRetriggeringTranslation() {
        var history = VisualSampleHistory()
        let baseline: [UInt16] = [1, 2, 3, 4]
        let changes = [history.observe(baseline), history.observe(baseline),
                       history.observe([9, 8, 7, 4]), history.observe([9, 8, 7, 4])]
        #expect(changes == [false, false, true, false])
    }

    @Test
    func subthresholdChangesAccumulateAgainstLastAcceptedFrame() {
        var history = VisualSampleHistory()
        _ = history.observe([1, 2, 3, 4])
        let changes = [history.observe([9, 2, 3, 4]), history.observe([9, 8, 3, 4]),
                       history.observe([9, 8, 7, 4]), history.observe([9, 8, 7])]
        #expect(changes == [false, false, true, true])
    }

    @Test
    func newWindowStartsWithItsOwnBaseline() {
        var history = VisualSampleHistory()
        _ = history.observe([1, 2, 3, 4])
        _ = history.observe([9, 8, 7, 4])
        history.reset()
        let changes = [history.observe([0, 0, 0, 0]), history.observe([0, 0, 0, 0]), history.observe([0, 6, 5, 4])]
        #expect(changes == [false, false, true])
    }
}
