import AppKit
import Observation
import SwiftUI
import UploadTheFileCore

/// The menu bar icon. Files dropped on it are published (a menu bar *window* closes the moment
/// focus moves to Finder, so it can never be a drop target); a click opens the popover with the
/// page list; a right-click (or control-click) shows a small menu.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let updates: AppUpdates
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var dropView: StatusDropView?
    private var isDragTargeted = false
    private var busyTimer: Timer?
    private var busyFrame = 0
    /// The popover's height now, in points; the width is always `PopoverSizing.width`. The first
    /// value is a guess until the content has reported what it needs.
    private var popoverHeight: Double = 300
    private var measuredHeight: Double?
    private var didApplyFirstHeight = false
    private var resizeTask: Task<Void, Never>?
    /// While the popover is opening or closing, further show and close requests are ignored.
    private var isPresenting = false
    /// How many times a resize waits for a drag to end (about ten seconds).
    private static let resizeRetries = 100

    init(model: AppModel, updates: AppUpdates) {
        self.model = model
        self.updates = updates
        super.init()
        configurePopover()
        model.presentStatus = { [weak self] in self?.presentStatus() }
        model.keepingStatusOpen = { [weak self] alert in
            guard let self else { return alert() }
            return self.keepingPopoverOpen(alert)
        }
        configureButton()
        updateIcon()
        trackIcon()
    }

    // MARK: Button

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("Upload the File")
        button.toolTip = "Upload the File"
        button.imageScaling = .scaleNone   // the artwork is drawn at its menu bar size (20 x 20 pt)

        // A transparent view over the button takes the drag. Its mouse events are handed straight
        // to the button (StatusDropView), so clicks and right-clicks behave as on any status item.
        let drop = StatusDropView(frame: button.bounds)
        drop.autoresizingMask = [.width, .height]
        drop.onTargetChange = { [weak self] targeted in self?.setDragTargeted(targeted) }
        drop.onDrop = { [weak self] urls in
            // After the drop animation, not inside its callback: AppKit spins the run loop while
            // it commits the drop (CoreDragCommitDropAnimationTransaction), and showing the popover
            // or a confirmation window there sends the layout pass into a loop (crash, 2026-11-16).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.receive(urls) }
        }
        button.addSubview(drop)
        dropView = drop
    }

    private func setDragTargeted(_ targeted: Bool) {
        guard targeted != isDragTargeted else { return }
        isDragTargeted = targeted
        statusItem.button?.highlight(targeted)
        updateIcon()
    }

    private func receive(_ urls: [URL]) {
        // Show the popover first so the progress and the result are right under the icon; a
        // confirmation window, when one is needed, then takes over from it.
        showPopover()
        model.publish(urls, intent: .publish, origin: .menu)
    }

    /// The model asks for the popover when a publish starts or ends. Nothing to do when it is
    /// already open: the progress and the result appear in it.
    private func presentStatus() {
        guard !popover.isShown else { return }
        showPopover()
    }

    // MARK: Icon

    private func updateIcon() {
        let busy = model.session.isActive
        if busy, busyTimer == nil { startBusyAnimation() }
        if !busy, busyTimer != nil { stopBusyAnimation() }

        let state: MenuBarIcon.State
        if isDragTargeted {
            state = .dropTarget
        } else if busy {
            state = .busy(frame: busyFrame)
        } else if model.isSignedIn {
            state = .idle
        } else {
            state = .signedOut
        }
        statusItem.button?.image = MenuBarIcon.image(for: state)
    }

    /// The arrow rises out of the box while a publish runs (12 fps). With Reduce Motion on, the
    /// icon holds the frame where the arrow rests above the box instead of looping.
    private func startBusyAnimation() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            busyFrame = 6
            busyTimer = Timer(timeInterval: 3600, repeats: true) { _ in }
            return
        }
        busyFrame = 0
        let timer = Timer(timeInterval: MenuBarIcon.busyFrameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.busyFrame = (self.busyFrame + 1) % MenuBarIcon.busyFrameCount
                self.updateIcon()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        busyTimer = timer
    }

    private func stopBusyAnimation() {
        busyTimer?.invalidate()
        busyTimer = nil
        busyFrame = 0
    }

    /// Re-reads the icon whenever a publish starts or ends, or the account signs in or out.
    private func trackIcon() {
        withObservationTracking {
            _ = model.session.isActive
            _ = model.isSignedIn
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateIcon()
                self?.trackIcon()
            }
        }
    }

    // MARK: Clicks

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if wantsMenu {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func showMenu() {
        closePopover()
        let menu = NSMenu()
        menu.addItem(item("Choose File…", #selector(publishFromMenu)))
        menu.addItem(item("Open Upload the File", #selector(openFromMenu)))
        menu.addItem(item("Manage Files on \(model.siteLabel)", #selector(manageFromMenu)))
        menu.addItem(.separator())
        let version = NSMenuItem(
            title: AppVersion.menuTitle(infoDictionary: Bundle.main.infoDictionary), action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(updates.checkForUpdatesItem())
        menu.addItem(item("Quit Upload the File", #selector(quitFromMenu), key: "q"))
        // Attaching the menu for one click lets AppKit position and highlight it like any other
        // menu bar menu; it is removed again so left-clicks keep opening the popover.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func publishFromMenu() { model.chooseAndPublish() }
    @objc private func openFromMenu() { showPopover() }
    @objc private func manageFromMenu() { model.openDashboard() }
    @objc private func quitFromMenu() { NSApp.terminate(nil) }

    // MARK: Popover

    private func configurePopover() {
        let content = MenuContentView(model: model, onContentHeight: { [weak self] height in
            self?.contentHeightChanged(height)
        })
        .onExitCommand { [weak self] in self?.closePopover() }
        let controller = NSHostingController(rootView: content)
        // The popover never takes its size from SwiftUI. The window frame and the SwiftUI layout
        // fed each other when the content changed during a drop (AppKit: "The window has been
        // marked as needing another Update Constraints in Window pass ...", a crash). The size is
        // set below, from the height the content reports, and only when it really changed.
        controller.sizingOptions = []
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: PopoverSizing.width, height: popoverHeight)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    // MARK: Popover size

    /// Called by the view whenever the height it needs at the fixed width changes. Only recorded
    /// here; the window follows once the height has held still (and no drag is over the app).
    private func contentHeightChanged(_ height: Double) {
        measuredHeight = height
        scheduleResize(retries: Self.resizeRetries)
    }

    private func scheduleResize(retries: Int) {
        resizeTask?.cancel()
        // The first measurement (the popover has just opened) is applied at once; later changes
        // wait until the height has held still.
        let delay = didApplyFirstHeight ? PopoverSizing.settleMilliseconds : 0
        resizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.applyMeasuredHeight(retries: retries)
        }
    }

    private func applyMeasuredHeight(retries: Int) {
        guard let measured = measuredHeight else { return }
        didApplyFirstHeight = true
        let dragging = isDragTargeted || model.isDropTargeted
        let screenLimit = (statusItem.button?.window?.screen ?? NSScreen.main).map { Double($0.visibleFrame.height) - 40 }
        guard let next = PopoverSizing.nextHeight(
            current: popoverHeight, measured: measured, isDragActive: dragging,
            maxHeight: screenLimit ?? PopoverSizing.maxHeight)
        else {
            // A drag is still over the app: look again shortly (the drop ends it).
            if dragging, retries > 0 { scheduleResize(retries: retries - 1) }
            return
        }
        popoverHeight = next
        popover.contentSize = NSSize(width: PopoverSizing.width, height: next)
    }

    /// Runs a modal alert while the popover stays where it is: it is made application-defined
    /// for the alert (so the alert's focus does not close it), then transient again, so a click
    /// anywhere else still closes it as usual. If it was open before, it is open after.
    func keepingPopoverOpen(_ alert: () -> Bool) -> Bool {
        let wasShown = popover.isShown
        popover.behavior = .applicationDefined
        let answer = alert()
        popover.behavior = .transient
        if wasShown {
            if popover.isShown {
                AppActivation.bringToFront()
                popover.contentViewController?.view.window?.makeKey()
            } else {
                showPopover()
            }
        }
        return answer
    }

    func togglePopover() {
        if popover.isShown { closePopover() } else { showPopover() }
    }

    /// Opens the popover under the icon. Does nothing when it is already open (a drop inside it
    /// starts a publish whose progress is *in* the popover) or while it is opening or closing.
    func showPopover() {
        guard !popover.isShown, !isPresenting, let button = statusItem.button else { return }
        isPresenting = true
        defer { isPresenting = false }
        AppActivation.bringToFront()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePopover() {
        guard popover.isShown, !isPresenting else { return }
        isPresenting = true
        defer { isPresenting = false }
        popover.performClose(nil)
    }

    func popoverWillShow(_ notification: Notification) {
        model.windowDidOpen()
    }
}

// MARK: - The drop target over the button

/// Accepts file drags. Highlighting and publishing are the controller's business; this reads the
/// pasteboard and asks `DroppedItems` what is worth taking.
@MainActor
final class StatusDropView: NSView {
    var onTargetChange: (Bool) -> Void = { _ in }
    var onDrop: ([URL]) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    // The view covers the button to receive drags; clicks belong to the button underneath.
    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { superview?.mouseUp(with: event) }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }
    override func rightMouseUp(with event: NSEvent) { superview?.rightMouseUp(with: event) }

    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        DroppedItems.isAcceptable(DragPasteboard.urls(from: sender.draggingPasteboard)) ? .copy : []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let result = operation(for: sender)
        onTargetChange(!result.isEmpty)
        return result
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetChange(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargetChange(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !operation(for: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargetChange(false)
        let urls = DroppedItems.publishableFileURLs(from: DragPasteboard.urls(from: sender.draggingPasteboard))
        guard !urls.isEmpty else { return false }
        onDrop(urls)
        return true
    }
}

enum DragPasteboard {
    /// Every URL on the pasteboard, files or not; `DroppedItems` decides which count.
    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
    }
}
