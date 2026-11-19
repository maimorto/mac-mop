import Foundation
import Testing
@testable import MacCleanerKit

@Suite("Scan ring progress creep")
struct ProgressCreepTests {
    @Test func frequentUpdatesShowTheRealValue() {
        // Malware-style: real 18 %, updated 0.5 s ago → shows 18 %, not 31 %.
        let v = ProgressCreep.displayed(progress: 0.18, target: 0.18, glideFrom: 0.17, waited: 0.5)
        #expect(abs(v - 0.18) < 1e-9)
    }

    @Test func glidesToNewValue() {
        let mid = ProgressCreep.displayed(progress: 0.5, target: 0.5, glideFrom: 0.3, waited: 0.1)
        #expect(mid > 0.3 && mid < 0.5)
    }

    @Test func sparseUpdatesCreepAtMostEightPoints() {
        let early = ProgressCreep.displayed(progress: 0.4, target: 0.4, glideFrom: 0.4, waited: 1.4)
        #expect(early == 0.4)
        let late = ProgressCreep.displayed(progress: 0.4, target: 0.4, glideFrom: 0.4, waited: 600)
        #expect(late > 0.47 && late <= 0.48 + 1e-9)
        let top = ProgressCreep.displayed(progress: 0.95, target: 0.95, glideFrom: 0.95, waited: 600)
        #expect(top <= 0.97 + 1e-9)
        let off = ProgressCreep.displayed(progress: 0.4, target: 0.4, glideFrom: 0.4, waited: 600, creeps: false)
        #expect(off == 0.4)
    }

    @Test func neverGoesBackwards() {
        // A creep reached 0.46, then real progress arrives at 0.42: target is
        // re-based to what was on screen, so the ring holds 0.46.
        var last = 0.0
        for w in stride(from: 0.0, through: 3, by: 0.05) {
            let v = ProgressCreep.displayed(progress: 0.42, target: 0.46, glideFrom: 0.46, waited: w)
            #expect(v >= 0.46 - 1e-9)
            #expect(v >= last - 1e-12)
            last = v
        }
        #expect(ProgressCreep.displayed(progress: 1, target: 0.5, glideFrom: 0.5, waited: 0) == 1)
    }
}
