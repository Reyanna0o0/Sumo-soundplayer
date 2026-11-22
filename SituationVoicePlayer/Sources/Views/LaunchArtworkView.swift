import SwiftUI

/// Mount once for cold launch; an explicit preview may mount a new instance.
/// Foreground changes do not restart this view's animation or completion timer.
struct LaunchArtworkView: View {
    var onCompletion: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt: Date?
    @State private var completed = false
    @State private var hasReducedMotion = false

    // Honor enabling the preference immediately. Turning it off takes effect
    // on the next presentation, so this one cannot reveal less artwork again
    // or extend a fade that has already started.
    private var effectiveReduceMotion: Bool { reduceMotion || hasReducedMotion }

    static let background = Color(red: 250 / 255, green: 248 / 255, blue: 242 / 255)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: completed)) { timeline in
            let elapsed = startedAt.map { max(0, timeline.date.timeIntervalSince($0)) } ?? 0
            let timing = LaunchArtworkTiming()
            LaunchArtworkFrame(progress: timing.progress(at: elapsed, reduceMotion: effectiveReduceMotion))
                .compositingGroup()
                .opacity(completed ? 0 : timing.opacity(at: elapsed, reduceMotion: effectiveReduceMotion))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("厮磨")
        .accessibilityIdentifier("launchArtwork")
        .onChange(of: reduceMotion, initial: true) { _, enabled in
            if enabled { hasReducedMotion = true }
        }
        .task(id: effectiveReduceMotion) {
            guard !completed else { return }
            // If an interrupted task is remounted with the same identity, finish
            // the remaining interval rather than replaying from the beginning.
            let start = startedAt ?? Date()
            startedAt = start
            let duration = LaunchArtworkTiming().duration(reduceMotion: effectiveReduceMotion)
            let remaining = max(0, duration - Date().timeIntervalSince(start))
            do { try await Task.sleep(for: .seconds(remaining)) }
            catch { return }
            guard !Task.isCancelled, !completed else { return }
            completed = true
            onCompletion()
        }
    }
}

/// A deterministic frame also used for static/reduced-motion display and QA.
struct LaunchArtworkFrame: View {
    var progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                LaunchArtworkView.background
                if let spec = LaunchArtworkSpecification.approved {
                    let frame = spec.imageFrame(in: geometry.size)
                    Image("LaunchArtwork")
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .mask {
                            if progress >= 1 { Color.white }
                            else { LaunchArtworkMask(spec: spec, drawing: spec.drawing(at: progress)) }
                        }
                        .offset(x: frame.minX, y: frame.minY)
                } else {
                    // A damaged/missing motion resource must not prevent startup.
                    Image("LaunchArtwork").resizable().scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
        }
        .ignoresSafeArea()
    }
}

struct LaunchArtworkMask: View {
    let spec: LaunchArtworkSpecification
    let drawing: Double

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / spec.sourceSize[0], y: size.height / spec.sourceSize[1])
            for track in spec.tracks {
                let progress = track.progress(at: drawing)
                guard progress > 0 else { continue }
                var trackContext = context
                if let minimumY = track.clipBelowY {
                    trackContext.clip(to: Path(CGRect(x: 0, y: minimumY, width: spec.sourceSize[0],
                                                     height: spec.sourceSize[1] - minimumY)))
                }
                trackContext.stroke(track.path.trimmedPath(from: 0, to: progress), with: .color(.white),
                                    style: StrokeStyle(lineWidth: track.width, lineCap: .round, lineJoin: .round))
            }
            for area in spec.areaReveals {
                let rect = area.rect(at: drawing)
                if rect.height > 0 { context.fill(Path(rect), with: .color(.white)) }
            }
            let crossing = spec.crossingGuard
            if drawing < crossing.activeUntil,
               let heart = spec.tracks.first(where: { $0.id == crossing.track }) {
                let circle = CGRect(x: crossing.center[0] - crossing.radius,
                                    y: crossing.center[1] - crossing.radius,
                                    width: crossing.radius * 2, height: crossing.radius * 2)
                // Remove the wide mask at the crossing to avoid exposing the
                // later branch early, then restore only the current narrow stroke.
                var clearContext = context
                clearContext.blendMode = .destinationOut
                clearContext.fill(Path(ellipseIn: circle), with: .color(.white))
                let progress = heart.progress(at: drawing)
                if progress > 0 {
                    context.stroke(heart.path.trimmedPath(from: 0, to: progress), with: .color(.white),
                                   style: StrokeStyle(lineWidth: crossing.strokeWidth, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}
