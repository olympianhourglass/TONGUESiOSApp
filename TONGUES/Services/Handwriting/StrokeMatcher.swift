import CoreGraphics
import Foundation

// Validates a single user-drawn stroke against the expected median stroke
// for the current character. Deterministic + offline. Order is enforced by
// the caller (it always passes the median for the next expected stroke);
// this type judges direction, endpoints, and overall shape.
enum StrokeMatcher {

    struct Result {
        let accepted: Bool
        /// 0 (perfect) … 1+ (far off). Useful for tuning / debugging.
        let error: Double
        let reason: String
    }

    /// - Parameters:
    ///   - user: captured stroke points in view coordinates.
    ///   - median: expected stroke's median in the same view coordinates.
    ///   - charSize: reference size (min side of the character rect) used to
    ///     scale every tolerance so matching is resolution-independent.
    static func match(user: [CGPoint], median: [CGPoint], charSize: CGFloat) -> Result {
        guard charSize > 0, median.count >= 2 else {
            return Result(accepted: false, error: 1, reason: "no-target")
        }
        // Reject accidental dots / taps: a real stroke covers meaningful
        // distance unless the target itself is a tiny stroke (e.g. a dot).
        let userLen = polylineLength(user)
        let medianLen = polylineLength(median)
        let minLen = max(medianLen * 0.35, charSize * 0.06)
        if user.count < 2 || userLen < minLen {
            return Result(accepted: false, error: 1, reason: "too-short")
        }

        let n = 16
        let u = resample(user, count: n)
        let m = resample(median, count: n)

        let start = distance(u.first!, m.first!) / charSize
        let end = distance(u.last!, m.last!) / charSize

        // Mean positional error between arc-length-aligned samples, in both
        // forward and reversed order — reversed is only used to detect that
        // the user drew the right shape but the WRONG direction.
        let meanFwd = meanPointError(u, m) / charSize
        let meanRev = meanPointError(u, m.reversed()) / charSize

        // Direction agreement of the overall stroke vector.
        let uVec = CGVector(dx: u.last!.x - u.first!.x, dy: u.last!.y - u.first!.y)
        let mVec = CGVector(dx: m.last!.x - m.first!.x, dy: m.last!.y - m.first!.y)
        let dir = dot(uVec, mVec) / max(magnitude(uVec) * magnitude(mVec), 0.0001)

        // Tolerances (fractions of the character size). Generous enough for
        // finger input, tight enough that a wrong stroke is rejected.
        let startTol = 0.30
        let endTol = 0.32
        let shapeTol = 0.23

        // Wrong direction but right shape: guide the learner explicitly.
        if meanRev + 0.02 < meanFwd, dir < 0.2 {
            return Result(accepted: false, error: meanFwd, reason: "wrong-direction")
        }
        if start > startTol {
            return Result(accepted: false, error: start, reason: "wrong-start")
        }
        if end > endTol {
            return Result(accepted: false, error: end, reason: "wrong-end")
        }
        if meanFwd > shapeTol {
            return Result(accepted: false, error: meanFwd, reason: "wrong-shape")
        }
        if dir < 0 {
            return Result(accepted: false, error: meanFwd, reason: "wrong-direction")
        }

        let score = 0.5 * meanFwd + 0.25 * start + 0.25 * end
        return Result(accepted: true, error: score, reason: "ok")
    }

    // MARK: Geometry helpers (shared with the template evaluator)

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    static func polylineLength(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count > 1 else { return 0 }
        var total: CGFloat = 0
        for i in 1..<pts.count { total += distance(pts[i], pts[i - 1]) }
        return total
    }

    /// Arc-length resample to exactly `count` evenly spaced points.
    static func resample(_ pts: [CGPoint], count: Int) -> [CGPoint] {
        let clean = pts
        guard clean.count > 1, count > 1 else {
            return Array(repeating: clean.first ?? .zero, count: count)
        }
        var cum: [CGFloat] = [0]
        for i in 1..<clean.count { cum.append(cum[i - 1] + distance(clean[i], clean[i - 1])) }
        let total = cum.last!
        guard total > 0 else { return Array(repeating: clean[0], count: count) }

        var out: [CGPoint] = []
        out.reserveCapacity(count)
        for k in 0..<count {
            let target = total * CGFloat(k) / CGFloat(count - 1)
            var j = 0
            while j < clean.count - 2 && cum[j + 1] < target { j += 1 }
            let seg = cum[j + 1] - cum[j]
            let t = seg == 0 ? 0 : (target - cum[j]) / seg
            out.append(CGPoint(
                x: clean[j].x + t * (clean[j + 1].x - clean[j].x),
                y: clean[j].y + t * (clean[j + 1].y - clean[j].y)
            ))
        }
        return out
    }

    private static func meanPointError(_ a: [CGPoint], _ b: [CGPoint]) -> CGFloat {
        let n = min(a.count, b.count)
        guard n > 0 else { return .greatestFiniteMagnitude }
        var sum: CGFloat = 0
        for i in 0..<n { sum += distance(a[i], b[i]) }
        return sum / CGFloat(n)
    }

    private static func dot(_ a: CGVector, _ b: CGVector) -> CGFloat { a.dx * b.dx + a.dy * b.dy }
    private static func magnitude(_ v: CGVector) -> CGFloat { hypot(v.dx, v.dy) }
}
