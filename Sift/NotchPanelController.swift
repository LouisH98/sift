import AppKit
import Combine
import KeyboardShortcuts
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
    private let chatModel = ThoughtChatModel()
    private let appearanceSettings = NotchAppearanceSettings.shared
    private var settingsCancellables = Set<AnyCancellable>()
    private var panel: NotchPanel?
    private var activationSurfaces: [ActivationSurface] = []
    private var pendingOrderOut: DispatchWorkItem?
    private var targetIsOpen = false
    private var keyEventMonitor: Any?
    private var scrollEventMonitor: Any?
    private var localActivationClickMonitor: Any?
    private var globalActivationClickMonitor: Any?
    private var screenParametersObserver: NSObjectProtocol?
    private var accumulatedHorizontalScroll: CGFloat = 0
    private var didPageDuringCurrentScrollGesture = false
    private var topEdgePushPressure: CGFloat = 0
    private var displayedTopEdgePushProgress: CGFloat = 0
    private var topEdgePushBeganAt: Date?
    private var lastTopEdgePushEventAt: Date?
    private var lastTopEdgePushPressureUpdateAt: Date?
    private var lastDisplayedTopEdgePushProgressUpdateAt: Date?
    private var topEdgePushDecayWorkItem: DispatchWorkItem?
    private var topEdgePushScreen: NSScreen?
    private var lastActivationClickAt = Date.distantPast
    private var lastTopEdgePushAt = Date.distantPast

    private let topBlurBleed: CGFloat = 32
    private let visibleWindowSize = NSSize(width: 640, height: 240)
    private let activationHitSize = NSSize(width: 430, height: 96)
    private let activationPanelSize = NSSize(width: 980, height: 220)
    private let fallbackClosedNotchSize = NSSize(width: 185, height: 32)
    private let topEdgePushThreshold: CGFloat = 68
    private let topEdgePushMinimumDuration: TimeInterval = 0.18
    private let topEdgeIntentionalBandHeight: CGFloat = 4
    private let topEdgePushMinimumDelta: CGFloat = 0.35
    private let topEdgePushPassiveLeakRate: CGFloat = 72
    private let topEdgePushPassiveLeakDelay: TimeInterval = 0.18
    private let topEdgePushPassiveLeakRampDuration: TimeInterval = 0.24
    private let topEdgePushCancelLeakRate: CGFloat = 220
    private let topEdgePushPullDownMinimumDelta: CGFloat = 1.6
    private let topEdgePushPullDownMultiplier: CGFloat = 1.25
    private let topEdgePushDecayInterval: TimeInterval = 1 / 120
    private let topEdgePushVisualChargeDuration: TimeInterval = 0.14
    private let shortcutModifierMask = NSEvent.ModifierFlags([.command, .option, .control, .shift])

    init(store: ThoughtStore) {
        self.store = store
        observeDebugSettings()
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
        targetIsOpen ? hide() : show()
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

    func show(on sourceScreen: NSScreen? = nil, activationGlowStrength: CGFloat = 0) {
        targetIsOpen = true
        pendingOrderOut?.cancel()
        pendingOrderOut = nil

        let panel = panel ?? makePanel()
        self.panel = panel
        let wasVisible = panel.isVisible

        animationModel.setPanelVisible(true)

        let screen = sourceScreen ?? activeScreen()
        let finalFrame = frame(on: screen)
        let closedNotchSize = closedNotchSize(on: screen)

        if !wasVisible {
            animationModel.prepareForPresentation(
                hideClosedNotch: shouldHideClosedNotch(on: screen),
                closedNotchSize: closedNotchSize
            )
        } else {
            animationModel.updateDisplayConfiguration(
                hideClosedNotch: shouldHideClosedNotch(on: screen),
                closedNotchSize: closedNotchSize
            )
        }
        animationModel.prepareOpeningGlow(strength: activationGlowStrength)

        panel.setFrame(finalFrame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startKeyEventMonitor()
        startScrollEventMonitor()
        PageNavigationShortcut.activateRegisteredShortcuts()

        animationModel.open()
        scheduleCurrentPageFocus()
    }

    func hide() {
        targetIsOpen = false
        pendingOrderOut?.cancel()
        pendingOrderOut = nil
        chatModel.resetSession()

        guard let panel else {
            return
        }

        animationModel.close()

        let orderOut = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel, !self.targetIsOpen, !self.animationModel.isOpen else {
                return
            }

            panel.orderOut(nil)
            panel.alphaValue = 1
            self.animationModel.setPanelVisible(false)
            self.pendingOrderOut = nil
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
                processor: .shared,
                actionNavigationModel: actionNavigationModel,
                chatModel: chatModel,
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
            self?.handlePassiveActivationEvent(
                type: event.type,
                mouseLocation: NSEvent.mouseLocation,
                deltaX: event.deltaX,
                deltaY: event.deltaY
            )
            return event
        }

        globalActivationClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            let eventType = event.type
            let deltaX = event.deltaX
            let deltaY = event.deltaY

            Task { @MainActor in
                self?.handlePassiveActivationEvent(
                    type: eventType,
                    mouseLocation: NSEvent.mouseLocation,
                    deltaX: deltaX,
                    deltaY: deltaY
                )
            }
        }
    }

    private func handlePassiveActivationEvent(type: NSEvent.EventType, mouseLocation: NSPoint, deltaX: CGFloat, deltaY: CGFloat) {
        if targetIsOpen {
            resetTopEdgePush()
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
            handleTopEdgePush(at: mouseLocation, deltaX: deltaX, deltaY: deltaY)
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
        guard !targetIsOpen else {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastActivationClickAt) > 0.24 else {
            return
        }

        guard let screen = NSScreen.screens.first(where: { activationClickFrame(on: $0).contains(mouseLocation) }) else {
            return
        }

        openFromMouseActivation(on: screen, at: now)
    }

    private func handleTopEdgePush(at mouseLocation: NSPoint, deltaX: CGFloat, deltaY: CGFloat) {
        let now = Date()

        guard let screen = topEdgePushScreen(at: mouseLocation) else {
            deflateTopEdgePush(rate: topEdgePushCancelLeakRate, at: now)
            return
        }

        guard mouseLocation.y >= screen.frame.maxY - topEdgeIntentionalBandHeight else {
            deflateTopEdgePush(rate: topEdgePushCancelLeakRate, at: now)
            return
        }

        topEdgePushScreen = screen

        let upwardPush = max(0, -deltaY)
        let downwardPull = max(0, deltaY)
        let isUpwardPush = upwardPush > topEdgePushMinimumDelta
        let pullDownMinimum = topEdgePushPressure > 0 ? topEdgePushPullDownMinimumDelta : topEdgePushMinimumDelta
        let isDownwardPull = downwardPull > pullDownMinimum

        guard isUpwardPush else {
            if isDownwardPull {
                topEdgePushPressure = max(0, topEdgePushPressure - (downwardPull * topEdgePushPullDownMultiplier))
                lastTopEdgePushPressureUpdateAt = now
                updateTopEdgePushProgress(on: screen, at: now)
            } else if topEdgePushPressure > 0 {
                lastTopEdgePushEventAt = now
                lastTopEdgePushPressureUpdateAt = now
            }

            scheduleTopEdgePushDecayIfNeeded()
            return
        }

        if topEdgePushBeganAt == nil || topEdgePushPressure <= 0.01 {
            topEdgePushBeganAt = now
        }
        lastTopEdgePushEventAt = now
        lastTopEdgePushPressureUpdateAt = now
        topEdgePushPressure = min(topEdgePushThreshold, topEdgePushPressure + upwardPush)
        updateTopEdgePushProgress(on: screen, at: now)
        scheduleTopEdgePushDecayIfNeeded()

        _ = openTopEdgePushIfReady(on: screen, at: now)
    }

    private func openTopEdgePushIfReady(on screen: NSScreen, at now: Date) -> Bool {
        guard
            let topEdgePushBeganAt,
            topEdgePushPressure >= topEdgePushThreshold,
            now.timeIntervalSince(topEdgePushBeganAt) >= topEdgePushMinimumDuration,
            now.timeIntervalSince(lastTopEdgePushAt) > 0.45,
            now.timeIntervalSince(lastActivationClickAt) > 0.24
        else {
            return false
        }

        lastTopEdgePushAt = now
        openFromMouseActivation(on: screen, at: now)

        return true
    }

    private func openFromMouseActivation(on screen: NSScreen, at date: Date = Date()) {
        guard !targetIsOpen else {
            return
        }

        lastActivationClickAt = date
        let activationGlowStrength = activationSurfaces
            .first(where: { $0.screen == screen })?
            .model
            .glowStrengthForTransition ?? 0

        let activationSurface = activationSurfaces.first(where: { $0.screen == screen })
        activationSurface?.model.commitOpeningHandoff()
        resetTopEdgePush(clearsActivationProgress: false)
        show(on: screen, activationGlowStrength: max(activationGlowStrength, 0.74))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            self?.endActivationHover()
        }
    }

    private func updateTopEdgePushProgress(on screen: NSScreen, at now: Date = Date()) {
        let targetProgress = min(1, topEdgePushPressure / topEdgePushThreshold)

        if targetProgress <= 0.001 {
            displayedTopEdgePushProgress = 0
        } else if targetProgress > displayedTopEdgePushProgress {
            let elapsed = lastDisplayedTopEdgePushProgressUpdateAt
                .map { max(0, now.timeIntervalSince($0)) }
                ?? topEdgePushDecayInterval
            let maximumStep = CGFloat(elapsed / topEdgePushVisualChargeDuration)
            displayedTopEdgePushProgress = min(targetProgress, displayedTopEdgePushProgress + maximumStep)
        } else {
            displayedTopEdgePushProgress = targetProgress
        }

        lastDisplayedTopEdgePushProgressUpdateAt = now

        activationSurfaces
            .first(where: { $0.screen == screen })?
            .model
            .updateActivationProgress(displayedTopEdgePushProgress)
    }

    private func applyTopEdgePushDecay(until now: Date = Date(), rate: CGFloat? = nil) {
        defer {
            lastTopEdgePushPressureUpdateAt = now
        }

        guard topEdgePushPressure > 0, let lastTopEdgePushPressureUpdateAt else {
            return
        }

        let elapsed = max(0, now.timeIntervalSince(lastTopEdgePushPressureUpdateAt))
        guard elapsed > 0 else {
            return
        }

        let decayRate = rate ?? passiveTopEdgePushLeakRate(at: now)
        guard decayRate > 0 else {
            return
        }

        topEdgePushPressure = max(0, topEdgePushPressure - CGFloat(elapsed) * decayRate)

        if topEdgePushPressure <= 0.001 {
            topEdgePushPressure = 0
            topEdgePushBeganAt = nil
            lastTopEdgePushEventAt = nil
        }
    }

    private func passiveTopEdgePushLeakRate(at now: Date) -> CGFloat {
        guard let lastTopEdgePushEventAt else {
            return topEdgePushPassiveLeakRate
        }

        let timeSincePush = now.timeIntervalSince(lastTopEdgePushEventAt)
        guard timeSincePush > topEdgePushPassiveLeakDelay else {
            return 0
        }

        let rampProgress = CGFloat((timeSincePush - topEdgePushPassiveLeakDelay) / topEdgePushPassiveLeakRampDuration)
        let easedRamp = NotchActivationHoverModel.smoothProximity(rampProgress)

        return topEdgePushPassiveLeakRate * easedRamp
    }

    private func deflateTopEdgePush(rate: CGFloat, at now: Date = Date()) {
        applyTopEdgePushDecay(until: now, rate: rate)

        if let topEdgePushScreen {
            updateTopEdgePushProgress(on: topEdgePushScreen, at: now)
        } else {
            activationSurfaces.forEach { $0.model.updateActivationProgress(0) }
        }

        scheduleTopEdgePushDecayIfNeeded()
    }

    private func scheduleTopEdgePushDecayIfNeeded() {
        topEdgePushDecayWorkItem?.cancel()
        topEdgePushDecayWorkItem = nil

        guard topEdgePushPressure > 0, !targetIsOpen else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.tickTopEdgePushDecay()
            }
        }
        topEdgePushDecayWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + topEdgePushDecayInterval, execute: workItem)
    }

    private func tickTopEdgePushDecay() {
        let now = Date()
        topEdgePushDecayWorkItem = nil

        if let topEdgePushScreen, openTopEdgePushIfReady(on: topEdgePushScreen, at: now) {
            return
        }

        applyTopEdgePushDecay(until: now)

        if let topEdgePushScreen {
            updateTopEdgePushProgress(on: topEdgePushScreen, at: now)

            if openTopEdgePushIfReady(on: topEdgePushScreen, at: now) {
                return
            }
        }

        if topEdgePushPressure > 0 {
            scheduleTopEdgePushDecayIfNeeded()
        } else {
            resetTopEdgePush()
        }
    }

    private func updateActivationHover(at mouseLocation: NSPoint) {
        for surface in activationSurfaces {
            let hoverFrame = activationHoverFrame(on: surface.screen)

            guard let localLocation = activationHoverLocation(mouseLocation, in: hoverFrame) else {
                surface.model.endHover()
                continue
            }

            surface.model.updateHover(location: localLocation, in: hoverFrame.size)
        }
    }

    private func activationHoverLocation(_ mouseLocation: NSPoint, in hoverFrame: NSRect) -> CGPoint? {
        let topEdgeAllowance: CGFloat = 3
        guard
            mouseLocation.x >= hoverFrame.minX,
            mouseLocation.x <= hoverFrame.maxX,
            mouseLocation.y >= hoverFrame.minY,
            mouseLocation.y <= hoverFrame.maxY + topEdgeAllowance
        else {
            return nil
        }

        return CGPoint(
            x: mouseLocation.x - hoverFrame.minX,
            y: min(mouseLocation.y - hoverFrame.minY, hoverFrame.height)
        )
    }

    private func endActivationHover() {
        activationSurfaces.forEach { $0.model.endHover() }
    }

    private func resetTopEdgePush(clearsActivationProgress: Bool = true) {
        topEdgePushDecayWorkItem?.cancel()
        topEdgePushDecayWorkItem = nil
        topEdgePushPressure = 0
        displayedTopEdgePushProgress = 0
        topEdgePushBeganAt = nil
        lastTopEdgePushEventAt = nil
        lastTopEdgePushPressureUpdateAt = nil
        lastDisplayedTopEdgePushProgressUpdateAt = nil
        topEdgePushScreen = nil

        if clearsActivationProgress {
            activationSurfaces.forEach { $0.model.updateActivationProgress(0) }
        }
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
                processor: .shared,
                notchModel: animationModel,
                notchSize: closedNotchSize(on: screen),
                size: activationPanelSize,
                usesTopEdgeLine: shouldHideClosedNotch(on: screen)
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

            if self.isToggleShortcut(event) {
                self.toggle()
                return nil
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
        if modifiers == .command {
            switch event.keyCode {
            case 126:
                actionNavigationModel.moveSelectedPriority(-1, store: store)
            case 125:
                actionNavigationModel.moveSelectedPriority(1, store: store)
            default:
                return false
            }

            return true
        }

        guard modifiers.isEmpty else {
            return false
        }

        switch event.keyCode {
        case 126:
            actionNavigationModel.moveSelection(-1, in: store.openActionItems + store.recentlyCompletedActionItems)
        case 125:
            actionNavigationModel.moveSelection(1, in: store.openActionItems + store.recentlyCompletedActionItems)
        case 36, 49, 76:
            actionNavigationModel.toggleSelected(in: store.openActionItems + store.recentlyCompletedActionItems, store: store)
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
            resetScrollGestureTracking()
            return false
        }

        let horizontal = event.scrollingDeltaX
        let vertical = event.scrollingDeltaY
        guard abs(horizontal) > abs(vertical) * 1.25, abs(horizontal) > 0.5 else {
            accumulatedHorizontalScroll = 0
            resetEndedScrollGesture(event)
            return false
        }

        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            resetScrollGestureTracking()
        }

        if !event.momentumPhase.isEmpty {
            resetEndedScrollGesture(event)
            return true
        }

        let isUnphasedWheelEvent = event.phase.isEmpty
        defer {
            if isUnphasedWheelEvent {
                resetScrollGestureTracking()
            } else {
                resetEndedScrollGesture(event)
            }
        }

        if didPageDuringCurrentScrollGesture {
            return true
        }

        accumulatedHorizontalScroll += horizontal

        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 22 : 2
        guard abs(accumulatedHorizontalScroll) >= threshold else {
            return true
        }

        didPageDuringCurrentScrollGesture = true
        let direction = accumulatedHorizontalScroll > 0 ? 1 : -1
        accumulatedHorizontalScroll = 0
        movePage(direction)

        return true
    }

    private func resetEndedScrollGesture(_ event: NSEvent) {
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
            resetScrollGestureTracking()
        }
    }

    private func resetScrollGestureTracking() {
        accumulatedHorizontalScroll = 0
        didPageDuringCurrentScrollGesture = false
    }

    private func stopScrollEventMonitor() {
        guard let scrollEventMonitor else {
            return
        }

        NSEvent.removeMonitor(scrollEventMonitor)
        self.scrollEventMonitor = nil
        resetScrollGestureTracking()
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
            targetIsOpen,
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
        case .chat:
            scheduleChatFocus()
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
            targetIsOpen,
            animationModel.selectedPage == .actions,
            let panel,
            panel.isVisible
        else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        guard let actionView = panel.contentView?.firstDescendant(withIdentifier: .siftActionKeyboardCatcher) else {
            return
        }

        if panel.firstResponder !== actionView {
            panel.makeFirstResponder(actionView)
        }
    }

    private func scheduleChatFocus() {
        focusChatInput()

        for delay in [0.04, 0.12, 0.24] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.focusChatInput()
            }
        }
    }

    private func focusChatInput() {
        guard
            targetIsOpen,
            animationModel.selectedPage == .chat,
            let panel,
            panel.isVisible
        else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        guard let chatInput = panel.contentView?.firstDescendant(withIdentifier: .siftChatInput),
              let textView = chatInput.firstDescendant(ofType: NSTextView.self) else {
            return
        }

        if panel.firstResponder !== textView {
            panel.makeFirstResponder(textView)
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
        let x = centeredX(for: size.width, on: screen)
        let y = screen.frame.maxY - visibleWindowSize.height

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func activationFrame(on screen: NSScreen) -> NSRect {
        let x = centeredX(for: activationPanelSize.width, on: screen)
        let y = screen.frame.maxY - activationPanelSize.height

        return NSRect(origin: CGPoint(x: x, y: y), size: activationPanelSize)
    }

    private func activationHoverFrame(on screen: NSScreen) -> NSRect {
        let x = centeredX(for: activationHitSize.width, on: screen)
        let y = screen.frame.maxY - activationHitSize.height

        return NSRect(origin: CGPoint(x: x, y: y), size: activationHitSize)
    }

    private func activationClickSize(on screen: NSScreen) -> NSSize {
        shouldHideClosedNotch(on: screen) ? topEdgePushSize(on: screen) : closedNotchSize(on: screen)
    }

    private func activationClickFrame(on screen: NSScreen) -> NSRect {
        let size = activationClickSize(on: screen)
        let x = centeredX(for: size.width, on: screen)
        let y = screen.frame.maxY - size.height

        return NSRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func topEdgePushScreen(at mouseLocation: NSPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            let size = topEdgePushSize(on: screen)
            let x = centeredX(for: size.width, on: screen)
            let topCenterXRange = x...(x + size.width)

            return topCenterXRange.contains(mouseLocation.x)
                && mouseLocation.y >= screen.frame.maxY - size.height
        }
    }

    private func closedNotchSize(on screen: NSScreen) -> NSSize {
        var size = fallbackClosedNotchSize

        if let topLeftWidth = screen.auxiliaryTopLeftArea?.width,
           let topRightWidth = screen.auxiliaryTopRightArea?.width {
            size.width = screen.frame.width - topLeftWidth - topRightWidth + 4
        }

        if screen.safeAreaInsets.top > 0 {
            size.height = screen.safeAreaInsets.top
        }

        return size
    }

    private func topEdgePushSize(on screen: NSScreen) -> NSSize {
        NSSize(width: closedNotchSize(on: screen).width, height: 10)
    }

    private func shouldHideClosedNotch(on screen: NSScreen) -> Bool {
        actualShouldHideClosedNotch(on: screen) || shouldSimulateNotchlessDisplay(on: screen)
    }

    private func actualShouldHideClosedNotch(on screen: NSScreen) -> Bool {
        (screen.auxiliaryTopLeftArea?.isEmpty ?? true) && (screen.auxiliaryTopRightArea?.isEmpty ?? true)
    }

    private func centeredX(for width: CGFloat, on screen: NSScreen) -> CGFloat {
        let centeredX = screen.frame.midX - (width / 2)

        return centeredX + debugNotchlessSimulationOffset(on: screen, surfaceWidth: width)
    }

    private func debugNotchlessSimulationOffset(on screen: NSScreen, surfaceWidth: CGFloat) -> CGFloat {
        #if DEBUG
        guard shouldSimulateNotchlessDisplay(on: screen) else {
            return 0
        }

        let desiredOffset = -(closedNotchSize(on: screen).width + 56)
        let minimumX = screen.frame.minX + 24
        let centeredX = screen.frame.midX - (surfaceWidth / 2)

        return max(desiredOffset, minimumX - centeredX)
        #else
        return 0
        #endif
    }

    private func shouldSimulateNotchlessDisplay(on screen: NSScreen) -> Bool {
        #if DEBUG
        appearanceSettings.debugSimulateNotchlessOnNotchedDisplays && !actualShouldHideClosedNotch(on: screen)
        #else
        false
        #endif
    }

    private func isToggleShortcut(_ event: NSEvent) -> Bool {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .toggleNotch) else {
            return false
        }

        let eventModifiers = event.modifierFlags.intersection(shortcutModifierMask)
        let shortcutModifiers = shortcut.modifiers.intersection(shortcutModifierMask)

        return Int(event.keyCode) == shortcut.carbonKeyCode && eventModifiers == shortcutModifiers
    }

    private func observeDebugSettings() {
        #if DEBUG
        appearanceSettings.$debugSimulateNotchlessOnNotchedDisplays
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else {
                    return
                }

                self.rebuildActivationPanels()

                guard let panel, panel.isVisible else {
                    return
                }

                let screen = self.activeScreen()
                let closedNotchSize = self.closedNotchSize(on: screen)
                self.animationModel.updateDisplayConfiguration(
                    hideClosedNotch: self.shouldHideClosedNotch(on: screen),
                    closedNotchSize: closedNotchSize
                )
                panel.setFrame(self.frame(on: screen), display: true)
            }
            .store(in: &settingsCancellables)
        #endif
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
    @Published private(set) var isContentMounted = false
    @Published private(set) var isContentPresented = false
    @Published private(set) var transitionGlowStrength: CGFloat = 0
    @Published private(set) var isPanelVisible = false
    @Published var captureDraft = ""
    @Published var selectedPage: NotchPage = .capture
    @Published private(set) var hideClosedNotch = true
    @Published private(set) var closedNotchSize = CGSize(width: 185, height: 32)
    private var pendingContentUnmount: DispatchWorkItem?
    private var pendingOpeningGlowFade: DispatchWorkItem?

    func setPanelVisible(_ isPanelVisible: Bool) {
        self.isPanelVisible = isPanelVisible
    }

    func prepareForPresentation(hideClosedNotch: Bool, closedNotchSize: CGSize) {
        pendingContentUnmount?.cancel()
        pendingContentUnmount = nil
        pendingOpeningGlowFade?.cancel()
        pendingOpeningGlowFade = nil
        self.hideClosedNotch = hideClosedNotch
        self.closedNotchSize = closedNotchSize
        isOpen = false
        isBlurred = true
        isContentMounted = false
        isContentPresented = false
        transitionGlowStrength = 0
        selectedPage = .capture
    }

    func updateClosedNotchSize(_ closedNotchSize: CGSize) {
        self.closedNotchSize = closedNotchSize
    }

    func updateDisplayConfiguration(hideClosedNotch: Bool, closedNotchSize: CGSize) {
        self.hideClosedNotch = hideClosedNotch
        self.closedNotchSize = closedNotchSize
    }

    func prepareOpeningGlow(strength: CGFloat) {
        pendingOpeningGlowFade?.cancel()
        pendingOpeningGlowFade = nil
        transitionGlowStrength = max(0, min(1, strength))
    }

    func open() {
        pendingContentUnmount?.cancel()
        pendingContentUnmount = nil
        isContentMounted = true

        withAnimation(Self.openAnimation) {
            isOpen = true
        }

        let fadeGlow = DispatchWorkItem { [weak self] in
            guard let self, self.isOpen else {
                return
            }

            withAnimation(Self.openingGlowAnimation) {
                self.transitionGlowStrength = 0
            }

            self.pendingOpeningGlowFade = nil
        }

        pendingOpeningGlowFade = fadeGlow
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: fadeGlow)

        withAnimation(Self.contentDismissalAnimation.delay(0.04)) {
            isContentPresented = true
        }

        withAnimation(Self.blurAnimation.delay(0.08)) {
            isBlurred = false
        }
    }

    func close() {
        pendingOpeningGlowFade?.cancel()
        pendingOpeningGlowFade = nil

        withAnimation(Self.contentDismissalAnimation) {
            isContentPresented = false
        }

        withAnimation(Self.blurAnimation) {
            isBlurred = true
        }

        withAnimation(Self.closeAnimation) {
            isOpen = false
        }

        let unmount = DispatchWorkItem { [weak self] in
            guard let self, !self.isOpen else {
                return
            }

            self.isContentMounted = false
            self.pendingContentUnmount = nil
        }

        pendingContentUnmount = unmount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: unmount)
    }

    func movePage(_ delta: Int) {
        guard isOpen else {
            return
        }

        withAnimation(Self.pageSwitchAnimation) {
            selectedPage = selectedPage.moving(delta)
        }
    }

    static var openAnimation: Animation {
        .interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0.12)
    }

    static var openingGlowAnimation: Animation {
        .smooth(duration: 0.72)
    }

    static var closeAnimation: Animation {
        .interactiveSpring(response: 0.36, dampingFraction: 1.0, blendDuration: 0.08)
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

    static var pageSwitchAnimation: Animation {
        .smooth(duration: 0.12)
    }

    static var pageResizeAnimation: Animation {
        .interactiveSpring(response: 0.24, dampingFraction: 0.92, blendDuration: 0.04)
    }

    static var contentDismissalAnimation: Animation {
        .smooth(duration: 0.16)
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
