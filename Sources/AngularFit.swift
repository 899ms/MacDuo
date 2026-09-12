import Foundation

/// Fits a straight line through recent readings, giving both where the lid is and how
/// fast it is turning.
///
/// Differencing consecutive readings is the obvious way to get a rate and it is close
/// to useless here: the sensor reports whole degrees, so every estimate is either zero
/// or one-over-the-interval. That is a square wave, not a rate, and a lid moved slowly
/// makes it worse, because a degree of dither across the boundary can send the estimate
/// briefly backwards. Low-passing it trades ripple for lag and keeps both.
///
/// A least-squares line uses every reading at once. Quantisation averages out, dither
/// cancels rather than accumulating, and the slope is steady enough to advance an
/// animation frame by frame. The same fit gives the position, evaluated at the newest
/// reading's own timestamp. That last detail matters: a low-pass filter suppresses
/// dither precisely by lagging behind it, whereas a line fitted to steady movement
/// passes through it and costs no delay.
///
/// The weighting is exponential rather than a sliding window. A window has an edge,
/// and every time the oldest reading falls off the far side the fit shifts a little;
/// on an otherwise even movement those shifts are visible as the occasional frame that
/// travels several times further than its neighbours.
struct AngularFit {
    struct Estimate {
        var angle: Double
        var degreesPerSecond: Double
    }

    /// Effective memory, which follows the speed of the lid.
    ///
    /// The fit's precision goes as the noise over the root of the sample count, and at
    /// walking pace a short window's error is the same size as the movement between one
    /// frame and the next, which is what the roughness at slow speeds actually was. A
    /// longer window fixes it and costs almost nothing, because a line fitted to steady
    /// movement has no lag however far back it reaches; only acceleration is delayed,
    /// and a lid moved slowly is not accelerating hard.
    ///
    /// Scaled to hold roughly this much travel, so it always spans a couple of degree
    /// boundaries whatever the speed.
    static let degreesOfMemory = 2.2
    static let shortestMemory: TimeInterval = 0.05
    static let longestMemory: TimeInterval = 0.4

    static func memory(forRate rate: Double) -> TimeInterval {
        guard abs(rate) > 0.001 else { return longestMemory }
        return clamp(degreesOfMemory / abs(rate), shortestMemory, longestMemory)
    }

    /// How far the fitted angle may sit from the reading it was fitted to.
    ///
    /// The sensor reports whole degrees, so the true angle is always within a degree of
    /// the last reading. Holding the fit to that turns it into a sub-degree estimate
    /// that cannot run away: when the lid stops the line still has slope for a moment,
    /// and without this the picture would carry on with it.
    static let maximumDeviation = 1.0
    /// A gap longer than this means the lid may have moved unobserved; start again.
    static let maximumGap: TimeInterval = 1.0

    private var weight = 0.0
    private var sumTime = 0.0
    private var sumTimeSquared = 0.0
    private var sumAngle = 0.0
    private var sumTimeAngle = 0.0
    private var lastTimestamp: TimeInterval?
    private var lastRate = 0.0

    mutating func reset() {
        weight = 0
        sumTime = 0
        sumTimeSquared = 0
        sumAngle = 0
        sumTimeAngle = 0
        lastTimestamp = nil
        lastRate = 0
    }

    mutating func update(angle: Double, at timestamp: TimeInterval) -> Estimate {
        guard let previous = lastTimestamp else {
            start(angle: angle, at: timestamp)
            return Estimate(angle: angle, degreesPerSecond: 0)
        }
        let elapsed = timestamp - previous
        guard elapsed > 0 else {
            return Estimate(angle: currentAngle(fallback: angle), degreesPerSecond: lastRate)
        }
        guard elapsed < Self.maximumGap else {
            start(angle: angle, at: timestamp)
            return Estimate(angle: angle, degreesPerSecond: 0)
        }

        // Age the accumulated fit, then move its origin to the new reading so the
        // arithmetic stays in small numbers regardless of how long the app has run.
        let decay = exp(-elapsed / Self.memory(forRate: lastRate))
        weight *= decay
        sumTime *= decay
        sumTimeSquared *= decay
        sumAngle *= decay
        sumTimeAngle *= decay

        sumTimeSquared += -2 * elapsed * sumTime + elapsed * elapsed * weight
        sumTime -= elapsed * weight
        sumTimeAngle -= elapsed * sumAngle

        weight += 1
        sumAngle += angle
        lastTimestamp = timestamp

        let determinant = weight * sumTimeSquared - sumTime * sumTime
        guard determinant > 1e-9 else {
            return Estimate(angle: currentAngle(fallback: angle), degreesPerSecond: lastRate)
        }
        lastRate = (weight * sumTimeAngle - sumTime * sumAngle) / determinant
        // The fitted line at the newest reading's own time: smoothed, but not behind,
        // and never further from the reading than the reading's own precision allows.
        let fitted = clamp(
            currentAngle(fallback: angle),
            angle - Self.maximumDeviation,
            angle + Self.maximumDeviation
        )
        return Estimate(angle: fitted, degreesPerSecond: lastRate)
    }

    /// The fitted line evaluated at the newest reading's own time.
    private func currentAngle(fallback: Double) -> Double {
        guard weight > 0 else { return fallback }
        return (sumAngle - lastRate * sumTime) / weight
    }

    private mutating func start(angle: Double, at timestamp: TimeInterval) {
        weight = 1
        sumTime = 0
        sumTimeSquared = 0
        sumAngle = angle
        sumTimeAngle = 0
        lastTimestamp = timestamp
        lastRate = 0
    }
}
