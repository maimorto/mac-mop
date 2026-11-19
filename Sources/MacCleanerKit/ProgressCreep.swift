import Foundation

/// Value shown by the scan progress ring between progress updates.
///
/// It glides to each new real value in 0.35 s. Only when updates are sparse
/// (nothing new for 1.5 s) does it creep further, at most 8 points and never
/// past 97 %, so modules that report in coarse steps never look frozen while
/// modules that report often show their true value. 100 % only when done.
public enum ProgressCreep {
    public static let glideDuration = 0.35
    public static let creepDelay = 1.5
    public static let creepRange = 0.08
    public static let creepCeiling = 0.97

    /// - Parameters:
    ///   - progress: latest real progress (0...1).
    ///   - target: real progress re-based on what was on screen at the last
    ///     update (`max(real, onScreen)`), so the ring never moves backwards.
    ///   - glideFrom: what was on screen when the last update arrived.
    ///   - waited: seconds since the last update.
    public static func displayed(progress: Double, target: Double, glideFrom: Double,
                                 waited: TimeInterval, creeps: Bool = true) -> Double {
        if progress >= 1 { return 1 }
        let target = min(max(max(progress, target), 0), 1)
        let from = min(glideFrom, target)
        let glide = min(max(waited / glideDuration, 0), 1)
        var value = from + (target - from) * (1 - pow(1 - glide, 3))
        if creeps, waited > creepDelay {
            let ceiling = min(target + creepRange, creepCeiling)
            value = target + max(0, ceiling - target) * (1 - exp(-(waited - creepDelay) / 5))
        }
        return max(value, from)
    }
}
