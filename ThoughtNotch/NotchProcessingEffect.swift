import SwiftUI

struct NotchProcessingEffect: View {
    let state: NotchProcessingState
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat
    let glowColor: Color
    var motionDurationScale: TimeInterval = 1
    var segmentLengthScale: CGFloat = 1

    private let motionClock = NotchProcessingMotionClock.shared

    @State private var pulseStartedAt: TimeInterval?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { timeline in
            GeometryReader { _ in
                let seconds = timeline.date.timeIntervalSinceReferenceDate
                let shape = NotchShape(
                    topCornerRadius: topCornerRadius,
                    bottomCornerRadius: bottomCornerRadius
                )
                let contour = NotchProcessingContour(
                    topCornerRadius: topCornerRadius,
                    bottomCornerRadius: bottomCornerRadius
                )
                let completion = completionProgress(seconds: seconds)
                let isVisible = state.isDistilling || completion < 1

                ZStack {
                    queuedGlow(shape: shape)

                    if state.isDistilling {
                        tracer(contour: contour, seconds: seconds)
                    }

                    completionPulse(contour: contour, progress: completion)
                }
                .opacity(isVisible ? 1 : 0)
                .animation(.smooth(duration: 0.28), value: state.isDistilling)
                .animation(.smooth(duration: 0.22), value: state.completionPulse)
            }
        }
        .compositingGroup()
        .onChange(of: state.completionPulse) { _, newValue in
            guard newValue > 0 else {
                pulseStartedAt = nil
                return
            }

            pulseStartedAt = Date().timeIntervalSinceReferenceDate
        }
    }

    private func queuedGlow(shape: NotchShape) -> some View {
        let opacity = state.isDistilling ? 0.18 : 0

        return shape
            .fill(
                RadialGradient(
                    colors: [
                        glowColor.opacity(opacity),
                        glowColor.opacity(opacity * 0.36),
                        .clear
                    ],
                    center: .bottom,
                    startRadius: 2,
                    endRadius: 132
                )
            )
            .blur(radius: state.isDistilling ? 9 : 13)
            .blendMode(.plusLighter)
    }

    private func tracer(contour: NotchProcessingContour, seconds: TimeInterval) -> some View {
        let duration = (state.isDistilling ? 1.95 : 3.0) * motionDurationScale
        let segmentLength = (state.isDistilling ? 0.17 : 0.1) * segmentLengthScale
        let phase = motionClock.phase(at: seconds, duration: duration)
        let range = squashedBounceRange(phase: phase, segmentLength: segmentLength)
        let opacity = state.isDistilling ? 0.92 : 0.56

        return Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let path = contour.path(in: rect)
            let trimmedPath = path.trimmedPath(from: range.start, to: range.end)

            var glowContext = context
            glowContext.blendMode = .plusLighter
            glowContext.addFilter(.blur(radius: 4.6))
            glowContext.stroke(
                trimmedPath,
                with: .color(glowColor.opacity(opacity * 0.3)),
                style: StrokeStyle(lineWidth: 5.4, lineCap: .round, lineJoin: .round)
            )

            var midGlowContext = context
            midGlowContext.blendMode = .plusLighter
            midGlowContext.addFilter(.blur(radius: 0.9))
            midGlowContext.stroke(
                trimmedPath,
                with: .color(glowColor.opacity(opacity * 0.56)),
                style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
            )

            var coreContext = context
            coreContext.blendMode = .plusLighter
            drawFadedTracerCore(
                in: &coreContext,
                path: path,
                rect: rect,
                range: range,
                opacity: opacity
            )
        }
    }

    private func completionPulse(contour: NotchProcessingContour, progress: CGFloat) -> some View {
        let opacity = max(0, 1 - progress)
        let lineWidth = 1 + progress * 6

        return ZStack {
            contour
                .stroke(glowColor.opacity(opacity * 0.45), lineWidth: lineWidth)
                .blur(radius: 8 + progress * 10)

            contour
                .stroke(.white.opacity(opacity * 0.56), lineWidth: max(0.6, 1.6 - progress))
        }
        .blendMode(.plusLighter)
        .opacity(opacity)
    }

    private func drawFadedTracerCore(
        in context: inout GraphicsContext,
        path: Path,
        rect: CGRect,
        range: (start: CGFloat, end: CGFloat),
        opacity: CGFloat
    ) {
        let center = (range.start + range.end) / 2
        let startPoint = contourPoint(at: range.start, in: rect)
        let centerPoint = contourPoint(at: center, in: rect)
        let endPoint = contourPoint(at: range.end, in: rect)
        let style = StrokeStyle(lineWidth: 0.82, lineCap: .butt, lineJoin: .round)

        context.stroke(
            path.trimmedPath(from: range.start, to: center),
            with: .linearGradient(
                Gradient(colors: [.white.opacity(0), .white.opacity(opacity)]),
                startPoint: startPoint,
                endPoint: centerPoint
            ),
            style: style
        )

        context.stroke(
            path.trimmedPath(from: center, to: range.end),
            with: .linearGradient(
                Gradient(colors: [.white.opacity(opacity), .white.opacity(0)]),
                startPoint: centerPoint,
                endPoint: endPoint
            ),
            style: style
        )
    }

    private func contourPoint(at progress: CGFloat, in rect: CGRect) -> CGPoint {
        let samples = contourSamples(in: rect)
        guard samples.count > 1 else {
            return CGPoint(x: rect.midX, y: rect.midY)
        }

        let clampedProgress = max(0, min(1, progress))
        var totalLength: CGFloat = 0

        for index in 1..<samples.count {
            totalLength += distance(from: samples[index - 1], to: samples[index])
        }

        guard totalLength > 0 else {
            return samples[0]
        }

        let targetLength = totalLength * clampedProgress
        var walkedLength: CGFloat = 0

        for index in 1..<samples.count {
            let previous = samples[index - 1]
            let current = samples[index]
            let segmentLength = distance(from: previous, to: current)

            if walkedLength + segmentLength >= targetLength {
                let segmentProgress = segmentLength > 0 ? (targetLength - walkedLength) / segmentLength : 0
                return CGPoint(
                    x: interpolate(from: previous.x, to: current.x, progress: segmentProgress),
                    y: interpolate(from: previous.y, to: current.y, progress: segmentProgress)
                )
            }

            walkedLength += segmentLength
        }

        return samples[samples.count - 1]
    }

    private func contourSamples(in rect: CGRect) -> [CGPoint] {
        let maximumRadius = max(0, min(rect.width / 2, rect.height / 2))
        let topCornerRadius = min(topCornerRadius, maximumRadius)
        let bottomCornerRadius = min(bottomCornerRadius, maximumRadius)
        var points: [CGPoint] = []

        func appendQuad(from start: CGPoint, control: CGPoint, to end: CGPoint) {
            for step in 1...8 {
                let progress = CGFloat(step) / 8
                let inverse = 1 - progress
                points.append(
                    CGPoint(
                        x: (inverse * inverse * start.x) + (2 * inverse * progress * control.x) + (progress * progress * end.x),
                        y: (inverse * inverse * start.y) + (2 * inverse * progress * control.y) + (progress * progress * end.y)
                    )
                )
            }
        }

        let start = CGPoint(x: rect.minX, y: rect.minY)
        points.append(start)

        let leftTopEnd = CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius)
        appendQuad(
            from: start,
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY),
            to: leftTopEnd
        )

        points.append(CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))

        let leftBottomEnd = CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY)
        appendQuad(
            from: points[points.count - 1],
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY),
            to: leftBottomEnd
        )

        points.append(CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))

        let rightBottomEnd = CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius)
        appendQuad(
            from: points[points.count - 1],
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY),
            to: rightBottomEnd
        )

        points.append(CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))

        appendQuad(
            from: points[points.count - 1],
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY),
            to: CGPoint(x: rect.maxX, y: rect.minY)
        )

        return points
    }

    private func distance(from start: CGPoint, to end: CGPoint) -> CGFloat {
        let xDelta = end.x - start.x
        let yDelta = end.y - start.y

        return sqrt((xDelta * xDelta) + (yDelta * yDelta))
    }

    private func squashedBounceRange(phase: CGFloat, segmentLength: CGFloat) -> (start: CGFloat, end: CGFloat) {
        let position = max(0, min(1, phase))
        let compressedLength = segmentLength * 0.56
        let travelDuration: CGFloat = 0.38
        let squeezeDuration: CGFloat = 0.06
        let recoverDuration: CGFloat = 0.06

        switch position {
        case 0..<travelDuration:
            let progress = position / travelDuration
            let start = progress * (1 - segmentLength)
            return (start, start + segmentLength)
        case travelDuration..<(travelDuration + squeezeDuration):
            let progress = eased((position - travelDuration) / squeezeDuration)
            let start = interpolate(from: 1 - segmentLength, to: 1 - compressedLength, progress: progress)
            return (start, 1)
        case (travelDuration + squeezeDuration)..<(travelDuration + squeezeDuration + recoverDuration):
            let progress = eased((position - travelDuration - squeezeDuration) / recoverDuration)
            let start = interpolate(from: 1 - compressedLength, to: 1 - segmentLength, progress: progress)
            return (start, 1)
        case 0.5..<(0.5 + travelDuration):
            let progress = (position - 0.5) / travelDuration
            let end = interpolate(from: 1, to: segmentLength, progress: progress)
            return (end - segmentLength, end)
        case (0.5 + travelDuration)..<(0.5 + travelDuration + squeezeDuration):
            let progress = eased((position - 0.5 - travelDuration) / squeezeDuration)
            let end = interpolate(from: segmentLength, to: compressedLength, progress: progress)
            return (0, end)
        default:
            let progress = eased((position - 0.5 - travelDuration - squeezeDuration) / recoverDuration)
            let end = interpolate(from: compressedLength, to: segmentLength, progress: progress)
            return (0, end)
        }
    }

    private func interpolate(from start: CGFloat, to end: CGFloat, progress: CGFloat) -> CGFloat {
        start + ((end - start) * progress)
    }

    private func eased(_ progress: CGFloat) -> CGFloat {
        let clampedProgress = max(0, min(1, progress))

        return clampedProgress * clampedProgress * (3 - (2 * clampedProgress))
    }

    private func completionProgress(seconds: TimeInterval) -> CGFloat {
        guard let pulseStartedAt else {
            return 1
        }

        let duration: TimeInterval = 0.72
        let elapsed = seconds - pulseStartedAt
        guard elapsed >= 0, elapsed <= duration else {
            return 1
        }

        return CGFloat(elapsed / duration)
    }
}

private final class NotchProcessingMotionClock {
    static let shared = NotchProcessingMotionClock()

    private var phase: CGFloat = 0
    private var lastSeconds: TimeInterval?

    func phase(at seconds: TimeInterval, duration: TimeInterval) -> CGFloat {
        guard duration > 0 else {
            return phase
        }

        defer {
            lastSeconds = seconds
        }

        guard let lastSeconds else {
            return phase
        }

        let elapsed = max(0, min(seconds - lastSeconds, 0.12))
        phase = (phase + CGFloat(elapsed / duration)).truncatingRemainder(dividingBy: 1)

        return phase
    }
}

private struct NotchProcessingContour: Shape {
    private var topCornerRadius: CGFloat
    private var bottomCornerRadius: CGFloat

    init(topCornerRadius: CGFloat, bottomCornerRadius: CGFloat) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get {
            .init(topCornerRadius, bottomCornerRadius)
        }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let maximumRadius = max(0, min(rect.width / 2, rect.height / 2))
        let topCornerRadius = min(topCornerRadius, maximumRadius)
        let bottomCornerRadius = min(bottomCornerRadius, maximumRadius)

        guard rect.width > 0, rect.height > 0 else {
            return path
        }

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )

        return path
    }
}
