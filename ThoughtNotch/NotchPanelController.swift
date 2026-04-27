import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchPanelController {
    private struct ActivationSurface {
        let panel: NotchActivationPanel
        let model: NotchActivationHoverModel
        let screen: NSScreen
    }

    private let store: ThoughtStore
    private let animationModel = NotchAnimationModel()
    private let actionNavigationModel = ActionListNavigationModel()
    private let appearanceSettings = NotchAppearanceSettings.shared
    private var panel: NotchPanel?
    private var activationSurfaces: [ActivationSurface] = []
    private var pendingOrderOut: DispatchWorkItem?
    private var keyEventMonitor: Any?
    private var scrollEventMonitor: Any?
    private var localActivationClickMonitor: Any?
    private var globalActivationClickMonitor: Any?
    private var screenParametersObserver: NSObjectProtocol?
    private var accumulatedHorizontalScroll: CGFloat = 0
    private var lastPageScrollAt = Date.distantPast
    private var lastActivationClickAt = Date.distantPast

    private let topBlurBleed: CGFloat = 32
    private let visibleWindowSize = NSSize(width: 640, height: 240)
    private let activationHitSize = NSSize(width: 380, height: 78)
    private let activationPanelSize = NSSize(width: 980, height: 220)
    private let notchActivationSize = NSSize(width: 185, height: 32)
    private let notchlessPushSize = NSSize(width: 185, height: 6)

    init(store: ThoughtStore) {
        self.store = store
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func installMouseActivationPanels() {
        guard screenParametersObserver == nil else {
            return
        }

        rebuildActivationPanels()
        startActivationClickMonitors()

        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildActivationPanels()
            }
        }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func movePage(_ delta: Int) {
        guard isVisible else {
            return
        }

        animationModel.movePage(delta)

        scheduleCurrentPageFocus()
    }

    func refreshPageShortcuts() {
        guard isVisible else {
            return
        }

        PageNavigationShortcut.activateRegisteredShortcuts()
    }

    func show(on sourceScreen: NSScreen? = nil) {
        pendingOrderOut?.cancel()
        pendingOrderOut = nil

        let panel = panel ?? makePanel()
        self.panel = panel

        let screen = sourceScreen ?? activeScreen()
        let finalFrame = frame(on: screen)

        animationModel.prepareForPresentation(hideClosedNotch: shouldHideClosedNotch(on: screen))
        panel.setFrame(finalFrame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startKeyEventMonitor()
        startScrollEventMonitor()
        PageNavigationShortcut.activateRegisteredShortcuts()

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.animationModel.open()
            self.focusCaptureTextView()
        }

        scheduleCurrentPageFocus()
    }

    func hide() {
        guard let panel else {
            return
        }

        animationModel.close()

        let orderOut = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel, !self.animationModel.isOpen else {
                return
            }

            panel.orderOut(nil)
            panel.alphaValue = 1
            self.stopKeyEventMonitor()
            self.stopScrollEventMonitor()
            PageNavigationShortcut.deactivateRegisteredShortcuts()
        }

        pendingOrderOut = orderOut
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42, execute: orderOut)
    }

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.onCancel = { [weak self] in
            Task { @MainActor in
                self?.hide()
            }
        }
        panel.onPageDelta = { [weak self] delta in
            Task { @MainActor in
                self?.movePage(delta)
            }
        }
        panel.contentView = NSHostingView(
            rootView: NotchView(
                model: animationModel,
                store: store,
                actionNavigationModel: actionNavigationModel,
                onSave: { [weak self] text in
                    Task { @MainActor in
                        guard let self else {
                            return
                        }

                        let thought = self.store.addThought(text)
                        ThoughtProcessor.shared.enqueue(thought)
                        self.hide()
                    }
                },
                onCancel: { [weak self] in
                    Task { @MainActor in
                        self?.hide()
                    }
                },
                onPageDelta: { [weak self] delta in
                    Task { @MainActor in
                        self?.movePage(delta)
                    }
                }
            )
        )

        return panel
    }

    private func rebuildActivationPanels() {
        activationSurfaces.forEach { $0.panel.close() }
        activationSurfaces = NSScreen.screens.map { makeActivationPanel(on: $0) }
    }

    private func startActivationClickMonitors() {
        guard localActivationClickMonitor == nil, globalActivationClickMonitor == nil else {
            return
        }

        let eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .mouseMoved, .leftMouseDragged]

        localActivationClickMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.handlePassiveActivationEvent(type: event.type, mouseLocation: NSEvent.mouseLocation)
            return event
        }

        globalActivationClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            let eventType = event.type

            Task { @MainActor in
                self?.handlePassiveActivationEvent(type: eventType, mouseLocation: NSEvent.mouseLocation)
            }
        }
    }

    private func handlePassiveActivationEvent(type: NSEvent.EventType, mouseLocation: NSPoint) {
        if isVisible {
            endActivationHover()

            if type == .leftMouseDown {
                handleOutsidePanelClick(at: mouseLocation)
            }

            return
        }

        updateActivationHover(at: mouseLocation)

        if type == .leftMouseDown {
            handleActivationClick(at: mouseLocation)
        } else {
            handleTopEdgePush(at: mouseLocation)
        }
    }

    private func handleOutsidePanelClick(at mouseLocation: NSPoint) {
        guard
            let panel,
            panel.isVisible,
            !panel.frame.contains(mouseLocation)
        else {
            return
        }

        hide()
    }

    private func handleActivationClick(at mouseLocation: NSPoint) {
        guard !isVisible else {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastActivationClickAt) > 0.24 else {
            return
        }

        guard let screen = NSScreen.screens.first(where: { activationClickFrame(on: $0).contains(mouseLocation) }) else {
            return
        }

        lastActivationClickAt = now
        endActivationHover()
        show(on: screen)
    }

    private func handleTopEdgePush(at mouseLocation: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { topEdgePushFrame(on: $0).contains(mouseLocation) }) else {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastActivationClickAt) > 0.24 else {
            return
        }

        lastActivationClickAt = now
        endActivationHover()
        show(on: screen)
    }

    private func updateActivationHover(at mouseLocation: NSPoint) {
        for surface in activationSurfaces {
            let hoverFrame = activationHoverFrame(on: surface.screen)

            guard hoverFrame.contains(mouseLocation) else {
                surface.model.endHover()
                continue
            }

            let localLocation = CGPoint(
                x: mouseLocation.x - hoverFrame.minX,
                y: mouseLocation.y - hoverFrame.minY
            )

            surface.model.updateHover(location: localLocation, in: hoverFrame.size)
        }
    }

    private func endActivationHover() {
        activationSurfaces.forEach { $0.model.endHover() }
    }

    private func makeActivationPanel(on screen: NSScreen) -> ActivationSurface {
        let panel = NotchActivationPanel(
            contentRect: activationFrame(on: screen),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let hoverModel = NotchActivationHoverModel()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(
            rootView: NotchActivationView(
                model: hoverModel,
                appearanceSettings: appearanceSettings,
                size: activationPanelSize
            )
        )
        panel.setFrame(activationFrame(on: screen), display: true)
        panel.orderFrontRegardless()

        return ActivationSurface(panel: panel, model: hoverModel, screen: screen)
    }

    private func startKeyEventMonitor() {
        guard keyEventMonitor == nil else {
            return
        }

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else {
                return event
            }

            if self.handleActionKeyDown(event) {
                return nil
            }

            if let direction = PageNavigationShortcut.direction(for: event) {
                self.movePage(direction)
                return nil
            }

            if event.keyCode == 53 {
                self.hide()
                return nil
            }

            return event
        }
    }

    private func handleActionKeyDown(_ event: NSEvent) -> Bool {
        guard animationModel.selectedPage == .actions else {
            return false
        }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty else {
            return false
        }

        switch event.keyCode {
        case 126:
            actionNavigationModel.moveSelection(-1, in: store.openActionItems)
        case 125:
            actionNavigationModel.moveSelection(1, in: store.openActionItems)
        case 36, 49, 76:
            actionNavigationModel.completeSelected(in: store.openActionItems, store: store)
        default:
            return false
        }

        return true
    }

    private func stopKeyEventMonitor() {
        guard let keyEventMonitor else {
            return
        }

        NSEvent.removeMonitor(keyEventMonitor)
        self.keyEventMonitor = nil
    }

    private func startScrollEventMonitor() {
        guard scrollEventMonitor == nil else {
            return
        }

        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.handlePageScroll(event) else {
                return event
            }

            return nil
        }
    }

    private func handlePageScroll(_ event: NSEvent) -> Bool {
        guard
            isVisible,
            animationModel.isOpen,
            let panel,
            panel.frame.contains(NSEvent.mouseLocation)
        else {
            accumulatedHorizontalScroll = 0
            return false
        }

        let horizontal = event.scrollingDeltaX
        let vertical = event.scrollingDeltaY
        guard abs(horizontal) > abs(vertical) * 1.25, abs(horizontal) > 0.5 else {
            accumulatedHorizontalScroll = 0
            return false
        }

        accumulatedHorizontalScroll += horizontal

        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 22 : 2
        guard abs(accumulatedHorizontalScroll) >= threshold else {
            return true
        }

        let now = Date()
        guard now.timeIntervalSince(lastPageScrollAt) > 0.24 else {
            return true
        }

        lastPageScrollAt = now
        let direction = accumulatedHorizontalScroll > 0 ? 1 : -1
        accumulatedHorizontalScroll = 0
        movePage(direction)

        return true
    }

    private func stopScrollEventMonitor() {
        guard let scrollEventMonitor else {
            return
        }

        NSEvent.removeMonitor(scrollEventMonitor)
        self.scrollEventMonitor = nil
        accumulatedHorizontalScroll = 0
    }

    private func scheduleCaptureFocus() {
        focusCaptureTextView()

        for delay in [0.04, 0.12, 0.24] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.focusCaptureTextView()
            }
        }
    }

    private func focusCaptureTextView() {
        guard
            animationModel.selectedPage == .capture,
            let panel,
            panel.isVisible
        else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        guard let textView = panel.contentView?.firstDescendant(ofType: NSTextView.self) else {
            return
        }

        if panel.firstResponder !== textView {
            panel.makeFirstResponder(textView)
        }
    }

    private func scheduleCurrentPageFocus() {
        switch animationModel.selectedPage {
        case .capture:
            scheduleCaptureFocus()
        case .actions:
            scheduleActionFocus()
        }
    }

    private func scheduleActionFocus() {
        focusActionKeyboardCatcher()

        for delay in [0.04, 0.12, 0.24] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.focusActionKeyboardCatcher()
            }
        }
    }

    private func focusActionKeyboardCatcher() {
        guard
            animationModel.selectedPage == .actions,
            let panel,
            panel.isVisible
        else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        guard let actionView = panel.contentView?.firstDescendant(withIdentifier: .thoughtNotchActionKeyboardCatcher) else {
            return
        }

        if panel.firstResponder !== actionView {
            panel.makeFirstResponder(actionView)
        }
    }

    private func activeScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation

        return NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private var windowSize: NSSize {
        NSSize(
            width: visibleWindowSize.width,
            height: visibleWindowSize.height + topBlurBleed
        )
    }

    private func frame(on screen: NSScreen) -> NSRect {
        let size = windowSize
        let x = screen.frame.midX - (size.width / 2)
        let y = screen.frame.maxY - visibleWindowSize.height

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func activationFrame(on screen: NSScreen) -> NSRect {
        let x = screen.frame.midX - (activationPanelSize.width / 2)
        let y = screen.frame.maxY - activationPanelSize.height

        return NSRect(origin: CGPoint(x: x, y: y), size: activationPanelSize)
    }

    private func activationHoverFrame(on screen: NSScreen) -> NSRect {
        let x = screen.frame.midX - (activationHitSize.width / 2)
        let y = screen.frame.maxY - activationHitSize.height

        return NSRect(origin: CGPoint(x: x, y: y), size: activationHitSize)
    }

    private func activationClickSize(on screen: NSScreen) -> NSSize {
        shouldHideClosedNotch(on: screen) ? notchlessPushSize : notchActivationSize
    }

    private func activationClickFrame(on screen: NSScreen) -> NSRect {
        let size = activationClickSize(on: screen)
        let x = screen.frame.midX - (size.width / 2)
        let y = screen.frame.maxY - size.height

        return NSRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func topEdgePushFrame(on screen: NSScreen) -> NSRect {
        let x = screen.frame.midX - (notchlessPushSize.width / 2)
        let y = screen.frame.maxY - notchlessPushSize.height

        return NSRect(origin: CGPoint(x: x, y: y), size: notchlessPushSize)
    }

    private func shouldHideClosedNotch(on screen: NSScreen) -> Bool {
        (screen.auxiliaryTopLeftArea?.isEmpty ?? true) && (screen.auxiliaryTopRightArea?.isEmpty ?? true)
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T {
            return match
        }

        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) {
                return match
            }
        }

        return nil
    }

    func firstDescendant(withIdentifier identifier: NSUserInterfaceItemIdentifier) -> NSView? {
        if self.identifier == identifier {
            return self
        }

        for subview in subviews {
            if let match = subview.firstDescendant(withIdentifier: identifier) {
                return match
            }
        }

        return nil
    }
}

@MainActor
final class NotchAnimationModel: ObservableObject {
    @Published var isOpen = false
    @Published var isBlurred = true
    @Published var selectedPage: NotchPage = .capture
    @Published private(set) var hideClosedNotch = true

    func prepareForPresentation(hideClosedNotch: Bool) {
        self.hideClosedNotch = hideClosedNotch
        isOpen = false
        isBlurred = true
        selectedPage = .capture
    }

    func open() {
        withAnimation(Self.openAnimation) {
            isOpen = true
        }

        withAnimation(Self.blurAnimation.delay(0.08)) {
            isBlurred = false
        }
    }

    func close() {
        withAnimation(Self.blurAnimation) {
            isBlurred = true
        }

        withAnimation(Self.closeAnimation) {
            isOpen = false
        }
    }

    func movePage(_ delta: Int) {
        guard isOpen else {
            return
        }

        withAnimation(Self.contentAnimation) {
            selectedPage = selectedPage.moving(delta)
        }
    }

    static var openAnimation: Animation {
        .interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)
    }

    static var closeAnimation: Animation {
        .spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
    }

    static var blurAnimation: Animation {
        .smooth(duration: 0.18)
    }

    static var contentAnimation: Animation {
        if #available(macOS 14.0, *) {
            .spring(.bouncy(duration: 0.4))
        } else {
            .timingCurve(0.16, 1, 0.3, 1, duration: 0.7)
        }
    }
}

final class NotchPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onPageDelta: ((Int) -> Void)?
    private var didCancelFromResign = false

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func resignKey() {
        super.resignKey()

        guard isVisible, !didCancelFromResign else {
            return
        }

        didCancelFromResign = true
        onCancel?()

        DispatchQueue.main.async { [weak self] in
            self?.didCancelFromResign = false
        }
    }

    override func keyDown(with event: NSEvent) {
        if let direction = PageNavigationShortcut.direction(for: event) {
            onPageDelta?(direction)
            return
        }

        if event.keyCode == 53 {
            onCancel?()
            return
        }

        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let direction = PageNavigationShortcut.direction(for: event) {
            onPageDelta?(direction)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}
