import SwiftUI

enum NotchPage: Int, CaseIterable {
    case capture
    case actions

    func moving(_ delta: Int) -> NotchPage {
        let pages = Self.allCases
        let currentIndex = pages.firstIndex(of: self) ?? 0
        let nextIndex = min(max(currentIndex + delta, 0), pages.count - 1)
        return pages[nextIndex]
    }
}

struct NotchView: View {
    @ObservedObject var model: NotchAnimationModel
    @ObservedObject var store: ThoughtStore
    @ObservedObject var actionNavigationModel: ActionListNavigationModel

    let onSave: (String) -> Void
    let onCancel: () -> Void
    let onPageDelta: (Int) -> Void

    private let closedSize = CGSize(width: 185, height: 32)
    private let openSize = CGSize(width: 540, height: 184)
    private let topBlurBleed: CGFloat = 32
    private let visibleStageHeight: CGFloat = 240

    private var currentSize: CGSize {
        if !model.isOpen && model.hideClosedNotch {
            return CGSize(width: 96, height: 4)
        }

        return model.isOpen ? openSize : closedSize
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
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(.black)
                                .frame(height: (!model.isOpen && model.hideClosedNotch) ? 0 : 1)
                                .padding(.horizontal, (!model.isOpen && model.hideClosedNotch) ? 0 : topCornerRadius)
                        }
                }
                .shadow(color: .black.opacity(model.isOpen ? 0.7 : 0), radius: model.isOpen ? 9 : 0, x: 0, y: 6)
                .opacity((!model.isOpen && model.hideClosedNotch) ? 0 : 1)
                .blur(radius: model.isBlurred ? 14 : 0)
                .animation(model.isOpen ? NotchAnimationModel.openAnimation : NotchAnimationModel.closeAnimation, value: model.isOpen)
                .animation(NotchAnimationModel.blurAnimation, value: model.isBlurred)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 640, height: visibleStageHeight + topBlurBleed, alignment: .top)
        .compositingGroup()
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var notchBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isOpen {
                VStack(alignment: .leading, spacing: 10) {
                    pageChrome

                    Group {
                        switch model.selectedPage {
                        case .capture:
                            ThoughtCaptureView(
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
                    .padding(.bottom, 20)
                    .transition(
                        .scale(scale: 0.8, anchor: .top)
                            .combined(with: .opacity)
                            .animation(.smooth(duration: 0.35))
                    )
                    .zIndex(1)
            } else {
                Rectangle()
                    .fill(.clear)
                    .frame(width: closedSize.width - 20, height: model.hideClosedNotch ? 0 : closedSize.height)
                    .transition(.opacity.animation(.smooth(duration: 0.12)))
            }
        }
        .padding(
            .horizontal,
            model.isOpen ? 12 : bottomCornerRadius
        )
        .padding(.bottom, model.isOpen ? 12 : 0)
        .animation(NotchAnimationModel.contentAnimation, value: model.isOpen)
    }

    private var pageChrome: some View {
        HStack(spacing: 6) {
            ForEach(NotchPage.allCases, id: \.self) { page in
                Button {
                    onPageDelta(page.rawValue - model.selectedPage.rawValue)
                } label: {
                    Circle()
                        .fill(page == model.selectedPage ? .white.opacity(0.76) : .white.opacity(0.22))
                        .frame(width: 5, height: 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Image(systemName: model.selectedPage == .capture ? "text.cursor" : "checklist")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.48))
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
        actionNavigationModel: ActionListNavigationModel(),
        onSave: { _ in },
        onCancel: {},
        onPageDelta: { _ in }
    )
        .frame(width: 640, height: 272)
        .background(.gray)
}
