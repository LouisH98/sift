import SwiftUI

enum NotchPage: Int, CaseIterable {
    case capture
    case actions

    var iconName: String {
        switch self {
        case .capture:
            return "text.bubble"
        case .actions:
            return "checklist"
        }
    }

    var title: String {
        switch self {
        case .capture:
            return "Capture thought"
        case .actions:
            return "Todo list"
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
    @ObservedObject private var appearanceSettings = NotchAppearanceSettings.shared

    let onSave: (String) -> Void
    let onCancel: () -> Void
    let onPageDelta: (Int) -> Void

    private let openSize = CGSize(width: 540, height: 184)
    private let topBlurBleed: CGFloat = 32
    private let visibleStageHeight: CGFloat = 240
    private let openingBlurRadius: CGFloat = 14
    private let contentDismissalBlurRadius: CGFloat = 22

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

    private var currentSize: CGSize {
        if !model.isOpen && model.hideClosedNotch {
            return CGSize(width: 96, height: 4)
        }

        return model.isOpen ? openSize : model.closedNotchSize
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

    var body: some View {
        ZStack(alignment: .top) {
            if appearanceSettings.isGlowEnabled {
                NotchGlowField(
                    strength: model.transitionGlowStrength,
                    notchSize: currentSize,
                    topCornerRadius: topCornerRadius,
                    bottomCornerRadius: bottomCornerRadius,
                    topOffset: topBlurBleed,
                    shape: (!model.isOpen && model.hideClosedNotch) ? .topEdgeLine : .notch
                )
                .opacity(model.transitionGlowStrength > 0.01 ? 1 : 0)
                .animation(NotchAnimationModel.openAnimation, value: model.isOpen)
                .animation(NotchAnimationModel.openingGlowAnimation, value: model.transitionGlowStrength)
                .allowsHitTesting(false)
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
                                    glowColor: appearanceSettings.glowColor,
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
                .opacity((!model.isOpen && model.hideClosedNotch) ? 0 : 1)
                .blur(radius: paneBlurRadius)
                .animation(model.isOpen ? NotchAnimationModel.openAnimation : NotchAnimationModel.closeAnimation, value: model.isOpen)
                .animation(NotchAnimationModel.blurAnimation, value: model.isBlurred)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if appearanceSettings.isGlowEnabled {
                transitionEdgeGlow
            }
        }
        .frame(width: 640, height: visibleStageHeight + topBlurBleed, alignment: .top)
        .compositingGroup()
        .preferredColorScheme(.dark)
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
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var notchBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isContentMounted {
                VStack(alignment: .leading, spacing: 10) {
                    pageChrome

                    Group {
                        switch model.selectedPage {
                        case .capture:
                            ThoughtCaptureView(
                                text: $model.captureDraft,
                                onSave: onSave,
                                onCancel: onCancel,
                                onPageDelta: onPageDelta
                            )
                        case .actions:
                            ActionChecklistView(
                                store: store,
                                navigationModel: actionNavigationModel,
                                onCancel: onCancel
                            )
                        }
                    }
                    .id(model.selectedPage)
                    .transition(
                        .scale(scale: 0.92, anchor: .top)
                            .combined(with: .opacity)
                            .animation(.smooth(duration: 0.18))
                    )
                }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, model.selectedPage == .capture ? 2 : 20)
                    .transition(
                        .scale(scale: 0.8, anchor: .top)
                            .combined(with: .opacity)
                            .animation(.smooth(duration: 0.35))
                    )
                    .zIndex(1)
                    .frame(
                        width: openSize.width - 24,
                        height: openSize.height,
                        alignment: .topLeading
                    )
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
        .frame(height: 10)
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
        onSave: { _ in },
        onCancel: {},
        onPageDelta: { _ in }
    )
        .frame(width: 640, height: 272)
        .background(.gray)
}
