import SwiftUI

enum NotchPage: Int, CaseIterable {
    case capture
    case actions
    case chat

    var iconName: String {
        switch self {
        case .capture:
            return "text.bubble"
        case .actions:
            return "checklist"
        case .chat:
            return "sparkle.magnifyingglass"
        }
    }

    var title: String {
        switch self {
        case .capture:
            return "Capture thought"
        case .actions:
            return "Todo list"
        case .chat:
            return "Chat"
        }
    }

    func moving(_ delta: Int) -> NotchPage {
        let pages = Self.allCases
        let currentIndex = pages.firstIndex(of: self) ?? 0
        let nextIndex = (currentIndex + delta).positiveModulo(pages.count)
        return pages[nextIndex]
    }
}

private extension Int {
    func positiveModulo(_ divisor: Int) -> Int {
        let remainder = self % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}

struct NotchView: View {
    @ObservedObject var model: NotchAnimationModel
    @ObservedObject var store: ThoughtStore
    @ObservedObject var processor: ThoughtProcessor
    @ObservedObject var actionNavigationModel: ActionListNavigationModel
    @ObservedObject var chatModel: ThoughtChatModel
    @ObservedObject private var appearanceSettings = NotchAppearanceSettings.shared
    @State private var processingFadeStartedAt: TimeInterval?

    let onSave: (String) -> Void
    let onCancel: () -> Void
    let onPageDelta: (Int) -> Void

    private let baseOpenSize = CGSize(width: 540, height: 184)
    private let chatOpenHeightIncrease: CGFloat = 50
    private let topBlurBleed: CGFloat = 32
    private let visibleStageHeight: CGFloat = 240
    private let openingBlurRadius: CGFloat = 14
    private let contentDismissalBlurRadius: CGFloat = 22
    private let pageContentTopPadding: CGFloat = 18
    private let pageChromeHeight: CGFloat = 10
    private let pageChromeSpacing: CGFloat = 10
    private let closedTopEdgeHeight: CGFloat = 5

    private var isNotchedDisplay: Bool {
        !model.hideClosedNotch
    }

    private var paneBlurRadius: CGFloat {
        model.isBlurred && !isNotchedDisplay ? openingBlurRadius : 0
    }

    private var contentBlurRadius: CGFloat {
        let presentationBlurRadius = model.isBlurred && isNotchedDisplay ? openingBlurRadius : 0
        let dismissalBlurRadius: CGFloat = model.isContentPresented ? 0 : contentDismissalBlurRadius

        return max(presentationBlurRadius, dismissalBlurRadius)
    }

    private var captureTextTopInset: CGFloat {
        pageContentTopPadding + pageChromeHeight + pageChromeSpacing
    }

    private var currentSize: CGSize {
        if !model.isOpen && model.hideClosedNotch {
            return CGSize(width: model.closedNotchSize.width, height: closedTopEdgeHeight)
        }

        return model.isOpen ? openSize : model.closedNotchSize
    }

    private var openSize: CGSize {
        CGSize(
            width: baseOpenSize.width,
            height: baseOpenSize.height + (model.selectedPage == .chat ? chatOpenHeightIncrease : 0)
        )
    }

    private var topCornerRadius: CGFloat {
        if !model.isOpen && model.hideClosedNotch {
            return 2
        }

        return model.isOpen ? 19 : 6
    }

    private var bottomCornerRadius: CGFloat {
        if !model.isOpen && model.hideClosedNotch {
            return 2
        }

        return model.isOpen ? 24 : 14
    }

    private var isDistilling: Bool {
        processor.notchProcessingState.isDistilling
    }

    private var isProcessingGlowActive: Bool {
        isDistilling || processingFadeStartedAt != nil
    }

    private var processingGlowStrength: CGFloat {
        guard processor.notchProcessingState.isDistilling else {
            return 0
        }

        return NotchProcessingGlowFade.steadyStrength
    }

    private var primaryGlowStrength: CGFloat {
        isProcessingGlowActive ? processingGlowStrength : model.transitionGlowStrength
    }

    private var glowShape: NotchGlowShape {
        (!model.isOpen && model.hideClosedNotch) ? .topEdgeLine : .notch
    }

    private var notchShellOpacity: CGFloat {
        if !model.isOpen && isProcessingGlowActive {
            return 0
        }

        return (!model.isOpen && model.hideClosedNotch) ? 0 : 1
    }

    private var glowStrengthAnimation: Animation? {
        if isDistilling {
            return nil
        }

        return .smooth(duration: NotchProcessingGlowFade.duration)
    }

    var body: some View {
        ZStack(alignment: .top) {
            if appearanceSettings.isGlowEnabled {
                if let processingFadeStartedAt {
                    TimelineView(.animation(minimumInterval: 1 / 120)) { timeline in
                        let fadeStrength = NotchProcessingGlowFade.strength(
                            startedAt: processingFadeStartedAt,
                            seconds: timeline.date.timeIntervalSinceReferenceDate
                        )

                        primaryGlowField(
                            strength: fadeStrength,
                            colorMotion: NotchProcessingGlowFade.motionStrength(for: fadeStrength)
                        )
                    }
                } else {
                    primaryGlowField(
                        strength: primaryGlowStrength,
                        colorMotion: isDistilling ? 1 : 0
                    )
                }
            }

            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(.black)
                        .frame(width: currentSize.width, height: topBlurBleed)

                    notchBody
                        .frame(width: currentSize.width, height: currentSize.height, alignment: .top)
                        .background(.black)
                        .clipShape(
                            NotchShape(
                                topCornerRadius: topCornerRadius,
                                bottomCornerRadius: bottomCornerRadius
                            )
                        )
                        .overlay {
                            if appearanceSettings.isGlowEnabled {
                                NotchProcessingEffect(
                                    state: processor.notchProcessingState,
                                    topCornerRadius: topCornerRadius,
                                    bottomCornerRadius: bottomCornerRadius,
                                    metalGlowColor: appearanceSettings.nsGlowColor,
                                    motionDurationScale: model.isOpen ? 1.85 : 1
                                )
                                .allowsHitTesting(false)
                            }
                        }
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(.black)
                                .frame(height: (!model.isOpen && model.hideClosedNotch) ? 0 : 1)
                                .padding(.horizontal, (!model.isOpen && model.hideClosedNotch) ? 0 : topCornerRadius)
                        }
                }
                .shadow(color: .black.opacity(model.isOpen ? 0.7 : 0), radius: model.isOpen ? 9 : 0, x: 0, y: 6)
                .opacity(notchShellOpacity)
                .blur(radius: paneBlurRadius)
                .animation(model.isOpen ? NotchAnimationModel.openAnimation : NotchAnimationModel.closeAnimation, value: model.isOpen)
                .animation(NotchAnimationModel.blurAnimation, value: model.isBlurred)
                .animation(NotchAnimationModel.pageResizeAnimation, value: currentSize.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if appearanceSettings.isGlowEnabled && !isProcessingGlowActive {
                transitionEdgeGlow
            }
        }
        .frame(width: 640, height: visibleStageHeight + topBlurBleed, alignment: .top)
        .compositingGroup()
        .preferredColorScheme(.dark)
        .onChange(of: isDistilling) { _, isDistilling in
            updateProcessingFade(isDistilling: isDistilling)
        }
    }

    private func primaryGlowField(strength: CGFloat, colorMotion: CGFloat) -> some View {
        NotchGlowField(
            strength: strength,
            notchSize: currentSize,
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            topOffset: topBlurBleed,
            shape: glowShape,
            colorMotion: colorMotion
        )
        .opacity(strength > 0.01 ? 1 : 0)
        .animation(NotchAnimationModel.openAnimation, value: model.isOpen)
        .animation(NotchAnimationModel.openingGlowAnimation, value: model.transitionGlowStrength)
        .animation(glowStrengthAnimation, value: strength)
        .animation(.smooth(duration: NotchProcessingGlowFade.duration), value: isDistilling)
        .allowsHitTesting(false)
    }

    private func updateProcessingFade(isDistilling: Bool) {
        if isDistilling {
            processingFadeStartedAt = nil
            return
        }

        let startedAt = Date().timeIntervalSinceReferenceDate
        processingFadeStartedAt = startedAt

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(NotchProcessingGlowFade.duration))
            if processingFadeStartedAt == startedAt {
                processingFadeStartedAt = nil
            }
        }
    }

    private var transitionEdgeGlow: some View {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
        .stroke(
            LinearGradient(
                colors: [
                    Color(red: 0.42, green: 0.78, blue: 1.0),
                    .white,
                    Color(red: 0.72, green: 0.42, blue: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            ),
            style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
        )
        .frame(width: currentSize.width, height: currentSize.height)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.18), location: 0),
                    .init(color: .white.opacity(0.52), location: 0.22),
                    .init(color: .white, location: 0.52),
                    .init(color: .white, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .shadow(color: Color(red: 0.48, green: 0.84, blue: 1.0).opacity(model.transitionGlowStrength * 0.44), radius: 5, x: -1, y: 1)
        .shadow(color: Color(red: 0.72, green: 0.42, blue: 1.0).opacity(model.transitionGlowStrength * 0.34), radius: 7, x: 1, y: 1)
        .opacity(model.transitionGlowStrength)
        .offset(y: topBlurBleed)
        .animation(NotchAnimationModel.openAnimation, value: model.isOpen)
        .animation(NotchAnimationModel.openingGlowAnimation, value: model.transitionGlowStrength)
        .animation(NotchAnimationModel.pageResizeAnimation, value: currentSize.height)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var notchBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isContentMounted {
                Group {
                    switch model.selectedPage {
                    case .capture:
                        ZStack(alignment: .topLeading) {
                            ThoughtCaptureView(
                                text: $model.captureDraft,
                                textTopInset: captureTextTopInset,
                                allowsAutoFocus: model.isOpen && model.isContentPresented,
                                onSave: onSave,
                                onCancel: onCancel,
                                onPageDelta: onPageDelta
                            )

                            pageChrome
                                .padding(.top, pageContentTopPadding)
                                .zIndex(1)
                        }
                    case .actions:
                        VStack(alignment: .leading, spacing: pageChromeSpacing) {
                            pageChrome

                            ActionChecklistView(
                                store: store,
                                navigationModel: actionNavigationModel,
                                onCancel: onCancel
                            )
                        }
                    case .chat:
                        VStack(alignment: .leading, spacing: pageChromeSpacing) {
                            pageChrome

                            NotchChatView(
                                store: store,
                                chatModel: chatModel,
                                onCancel: onCancel,
                                onPageDelta: onPageDelta
                            )
                            .frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                }
                .id(model.selectedPage)
                .transition(
                    .scale(scale: 0.92, anchor: .top)
                        .combined(with: .opacity)
                        .animation(NotchAnimationModel.pageSwitchAnimation)
                )
                    .padding(.horizontal, 18)
                    .padding(.top, model.selectedPage == .capture ? 0 : pageContentTopPadding)
                    .padding(.bottom, model.selectedPage == .capture ? 2 : 20)
                    .zIndex(1)
                    .frame(
                        width: openSize.width - 24,
                        height: openSize.height,
                        alignment: .topLeading
                    )
                    .animation(NotchAnimationModel.pageResizeAnimation, value: openSize.height)
                    .opacity(model.isContentPresented ? 1 : 0)
                    .blur(radius: model.isContentPresented ? 0 : contentDismissalBlurRadius)
                    .animation(NotchAnimationModel.contentDismissalAnimation, value: model.isContentPresented)
                    .allowsHitTesting(model.isContentPresented)
            } else {
                Rectangle()
                    .fill(.clear)
                    .frame(width: model.closedNotchSize.width - 20, height: model.hideClosedNotch ? 0 : model.closedNotchSize.height)
                    .transition(.opacity.animation(.smooth(duration: 0.12)))
            }
        }
        .padding(
            .horizontal,
            model.isOpen ? 12 : bottomCornerRadius
        )
        .padding(.bottom, model.isOpen && model.selectedPage != .capture ? 12 : 0)
        .blur(radius: contentBlurRadius)
        .animation(NotchAnimationModel.contentAnimation, value: model.isOpen)
        .animation(NotchAnimationModel.blurAnimation, value: model.isBlurred)
    }

    private var pageChrome: some View {
        HStack(spacing: 6) {
            ForEach(NotchPage.allCases, id: \.self) { page in
                Button {
                    onPageDelta(page.rawValue - model.selectedPage.rawValue)
                } label: {
                    Image(systemName: page.iconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(page == model.selectedPage ? .white.opacity(0.78) : .white.opacity(0.32))
                        .frame(width: 18, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(page.title)
                .help(page.title)
            }
        }
        .frame(height: pageChromeHeight)
    }
}

struct NotchShape: Shape {
    private var topCornerRadius: CGFloat
    private var bottomCornerRadius: CGFloat

    init(topCornerRadius: CGFloat = 6, bottomCornerRadius: CGFloat = 14) {
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
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))

        return path
    }
}

#Preview {
    NotchView(
        model: NotchAnimationModel(),
        store: .shared,
        processor: .shared,
        actionNavigationModel: ActionListNavigationModel(),
        chatModel: ThoughtChatModel(),
        onSave: { _ in },
        onCancel: {},
        onPageDelta: { _ in }
    )
        .frame(width: 640, height: 272)
        .background(.gray)
}
