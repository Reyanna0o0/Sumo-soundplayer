import SwiftUI
import UIKit

/// Keep the approved drawing intact, then dissolve the whole artwork/background
/// together over the already-laid-out destination. No scale or slide is applied.
struct LaunchArtworkTiming {
    let drawingDuration: TimeInterval
    static let exitDuration: TimeInterval = 0.38
    static let reducedMotionExitDuration: TimeInterval = 0.16

    init(drawingDuration: TimeInterval = LaunchArtworkSpecification.approved?.duration ?? 2.2) {
        self.drawingDuration = drawingDuration
    }

    func duration(reduceMotion: Bool) -> TimeInterval {
        drawingDuration + (reduceMotion ? Self.reducedMotionExitDuration : Self.exitDuration)
    }

    func progress(at elapsed: TimeInterval, reduceMotion: Bool) -> Double {
        reduceMotion ? 1 : min(1, max(0, elapsed / drawingDuration))
    }

    func opacity(at elapsed: TimeInterval, reduceMotion: Bool) -> Double {
        let exit = reduceMotion ? Self.reducedMotionExitDuration : Self.exitDuration
        let fraction = min(1, max(0, (elapsed - drawingDuration) / exit))
        // Smoothstep has zero velocity at both ends, so the complete drawing
        // settles into the transition and the interface arrives without a cut.
        return 1 - fraction * fraction * (3 - 2 * fraction)
    }
}

/// The approved 2026-11-18 artwork handoff is bundled unchanged in LaunchMotion.
/// Paths reveal the original PNG; they are never used as visible replacement artwork.
struct LaunchArtworkSpecification: Decodable {
    struct Placement: Decodable { let scale: Double; let x: Double; let y: Double }
    struct TimeKey: Decodable { let time: Double; let drawing: Double }
    struct Track: Decodable {
        let id: String
        let start: Double
        let end: Double
        let width: Double
        let clipBelowY: Double?
        let path: Path

        enum CodingKeys: String, CodingKey { case id, start, end, width, clipBelowY, d }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            start = try values.decode(Double.self, forKey: .start)
            end = try values.decode(Double.self, forKey: .end)
            width = try values.decode(Double.self, forKey: .width)
            clipBelowY = try values.decodeIfPresent(Double.self, forKey: .clipBelowY)
            path = try LaunchArtworkSpecification.parsePath(values.decode(String.self, forKey: .d))
        }

        func progress(at drawing: Double) -> Double {
            min(1, max(0, (drawing - start) / (end - start)))
        }
    }
    struct Area: Decodable {
        let x: Double; let y: Double; let width: Double; let height: Double
        let start: Double; let end: Double
        func rect(at drawing: Double) -> CGRect {
            let progress = min(1, max(0, (drawing - start) / (end - start)))
            return CGRect(x: x, y: y + height * (1 - progress), width: width, height: height * progress)
        }
    }
    struct CrossingGuard: Decodable {
        let center: [Double]
        let radius: Double
        let strokeWidth: Double
        let activeUntil: Double
        let track: String
    }

    let sourceSize: [Double]
    let screenSize: [Double]
    let duration: Double
    let placement: Placement
    let tracks: [Track]
    let areaReveals: [Area]
    let crossingGuard: CrossingGuard
    let timeMap: [TimeKey]
    let revision: Int

    static let approved: Self? = {
        guard let data = NSDataAsset(name: "LaunchMotion")?.data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }()

    /// Monotone cubic Hermite mapping from elapsed time to drawing progress,
    /// matching drawingAt() in the approved interactive preview.
    func drawing(at time: Double) -> Double {
        guard time.isFinite, time > 0 else { return 0 }
        guard time < 1 else { return 1 }
        let intervals = zip(timeMap, timeMap.dropFirst()).map { $1.time - $0.time }
        let secants = zip(timeMap, timeMap.dropFirst()).enumerated().map {
            ($0.element.1.drawing - $0.element.0.drawing) / intervals[$0.offset]
        }
        let slopes = timeMap.indices.map { index -> Double in
            if index == 0 { return secants[0] }
            if index == timeMap.count - 1 { return secants[secants.count - 1] }
            guard secants[index - 1] * secants[index] > 0 else { return 0 }
            let before = 2 * intervals[index] + intervals[index - 1]
            let after = intervals[index] + 2 * intervals[index - 1]
            return (before + after) / (before / secants[index - 1] + after / secants[index])
        }
        guard let index = timeMap.indices.dropLast().first(where: {
            time >= timeMap[$0].time && time < timeMap[$0 + 1].time
        }) else { return 1 }
        let left = timeMap[index], right = timeMap[index + 1], span = intervals[index]
        let u = (time - left.time) / span, u2 = u * u, u3 = u2 * u
        let drawing = (2 * u3 - 3 * u2 + 1) * left.drawing
            + (u3 - 2 * u2 + u) * span * slopes[index]
            + (-2 * u3 + 3 * u2) * right.drawing
            + (u3 - u2) * span * slopes[index + 1]
        return min(right.drawing, max(left.drawing, drawing))
    }

    /// Fits the reference height/width while keeping the actual first stroke
    /// at the left edge (the PNG has transparent margins).
    func imageFrame(in viewport: CGSize) -> CGRect {
        let fit = min(viewport.width / screenSize[0], viewport.height / screenSize[1])
        return CGRect(x: placement.x * fit,
                      y: (viewport.height - screenSize[1] * fit) / 2 + placement.y * fit,
                      width: sourceSize[0] * placement.scale * fit,
                      height: sourceSize[1] * placement.scale * fit)
    }

    private enum PathError: Error { case invalidApprovedPath }

    /// The approved SVG geometry contains only absolute M, L, Q and C commands.
    /// Parse once while decoding, rather than reparsing at animation frame rate.
    private static func parsePath(_ svg: String) throws -> Path {
        let tokens = svg.split(whereSeparator: { $0.isWhitespace || $0 == "," })
        var index = 0
        var path = Path()
        func point() throws -> CGPoint {
            guard index + 1 < tokens.count, let x = Double(tokens[index]),
                  let y = Double(tokens[index + 1]) else { throw PathError.invalidApprovedPath }
            index += 2
            return CGPoint(x: x, y: y)
        }
        while index < tokens.count {
            let command = tokens[index]
            index += 1
            switch command {
            case "M": path.move(to: try point())
            case "L": path.addLine(to: try point())
            case "Q":
                let control = try point(), end = try point()
                path.addQuadCurve(to: end, control: control)
            case "C":
                let first = try point(), second = try point(), end = try point()
                path.addCurve(to: end, control1: first, control2: second)
            default: throw PathError.invalidApprovedPath
            }
        }
        return path
    }
}
