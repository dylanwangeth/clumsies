import AppKit
import Combine
import SwiftUI

private enum MainWindowSurface: Equatable {
    case loading
    case workspace
    case failure
}

@MainActor
enum SettingsWindowLayout {
    static let defaultContentSize = NSSize(width: 620, height: 470)
    static let minimumContentSize = NSSize(width: 520, height: 400)

    static func configure(_ window: NSWindow, pane: SettingsPane) {
        window.styleMask.remove(.miniaturizable)
        window.styleMask.remove(.resizable)
        window.title = pane.title
        window.toolbarStyle = .preference
        window.toolbar?.allowsUserCustomization = false
        window.toolbar?.autosavesConfiguration = false
        window.toolbar?.displayMode = .iconAndLabel
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
    }

    static func normalize(_ window: NSWindow, pane: SettingsPane) {
        configure(window, pane: pane)
        window.contentMinSize = minimumContentSize
        let contentSize = window.contentLayoutRect.size
        guard contentSize.width < minimumContentSize.width
            || contentSize.height < minimumContentSize.height
        else {
            return
        }
        window.setContentSize(defaultContentSize)
    }
}

@MainActor
final class SettingsTabViewController: NSTabViewController {
    private let panes: [SettingsPane]
    private let defaults: UserDefaults

    init(
        items: [(SettingsPane, NSViewController)],
        selectedPane: SettingsPane,
        defaults: UserDefaults = .standard
    ) {
        panes = items.map(\.0)
        self.defaults = defaults
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        for (pane, controller) in items {
            controller.title = pane.title
            let item = NSTabViewItem(viewController: controller)
            item.identifier = pane.rawValue
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.systemImage, accessibilityDescription: pane.title)
            addTabViewItem(item)
        }
        selectedTabViewItemIndex = panes.firstIndex(of: selectedPane) ?? 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var selectedPane: SettingsPane {
        panes.indices.contains(selectedTabViewItemIndex)
            ? panes[selectedTabViewItemIndex]
            : .general
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let rawValue = tabViewItem?.identifier as? String,
              let pane = SettingsPane(rawValue: rawValue) else {
            return
        }
        pane.persist(in: defaults)
        view.window?.title = pane.title
    }
}

@MainActor
enum DiagnosticsWindowLayout {
    static func configure(_ window: NSWindow, destination: DiagnosticsDestination) {
        window.title = destination.title
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.contentMinSize = destination.minimumContentSize
    }

    static func normalize(_ window: NSWindow, destination: DiagnosticsDestination) {
        configure(window, destination: destination)
        let contentSize = window.contentLayoutRect.size
        guard contentSize.width < destination.minimumContentSize.width
            || contentSize.height < destination.minimumContentSize.height
        else {
            return
        }
        window.setContentSize(destination.defaultContentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let store = WorkspaceStore()
    private let softwareUpdateController = SoftwareUpdateController()
    private var phaseObservation: AnyCancellable?
    private var mainWindow: NSWindow?
    private var authenticationWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var diagnosticsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private lazy var statusMenu = makeStatusMenu()
    private var isFlushingForTermination = false
    private var mainWindowSurface: MainWindowSurface?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installApplicationMenu()
        installStatusItem()
        observePhase()
        NSApp.activate(ignoringOtherApps: true)
        store.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        restorePrimaryWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store.hasPendingChanges else { return .terminateNow }
        guard !isFlushingForTermination else { return .terminateLater }
        isFlushingForTermination = true
        Task { [weak self] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            let didSave = await store.flushPendingChanges()
            isFlushingForTermination = false
            if !didSave {
                presentMainWindow()
            }
            sender.reply(toApplicationShouldTerminate: didSave)
        }
        return .terminateLater
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(newProject(_:)) {
            return store.canManageProjects && store.phase == .ready
        }
        if menuItem.action == #selector(newMemory(_:)) {
            guard store.selectedSection == .memory else { return false }
            return store.canCreateMemory(kind: store.selectedKind, scope: .org)
        }
        if menuItem.action == #selector(closeActiveTab(_:)) {
            return store.activeVisibleTab != nil
        }
        if menuItem.action == #selector(toggleSidebar(_:)) {
            menuItem.title = store.sidebarExpanded ? "Hide Sidebar" : "Show Sidebar"
        }
        if menuItem.action == #selector(approveReview(_:)) {
            return store.canPerformReviewMenuAction(.approve)
        }
        if menuItem.action == #selector(rejectReview(_:)) {
            return store.canPerformReviewMenuAction(.reject)
        }
        if menuItem.action == #selector(mergeReview(_:)) {
            return store.canPerformReviewMenuAction(.merge)
        }
        if menuItem.action == #selector(resubmitReview(_:)) {
            return store.canPerformReviewMenuAction(.resubmit)
        }
        return true
    }

    private func observePhase() {
        phaseObservation = store.$phase
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                self?.present(phase)
            }
    }

    private func present(_ phase: ApplicationPhase) {
        switch phase {
        case .launching:
            presentMainLoading()
        case .loading:
            if authenticationWindow?.isVisible == true {
                presentAuthenticationContent(LaunchView())
            } else if mainWindowSurface != .workspace {
                presentMainLoading()
            }
        case .authenticationRequired:
            mainWindow?.orderOut(nil)
            presentAuthenticationContent(AuthenticationView(store: store))
        case .ready:
            authenticationWindow?.orderOut(nil)
            authenticationWindow = nil
            presentMainWindow()
        case .failed(let message):
            authenticationWindow?.orderOut(nil)
            authenticationWindow = nil
            presentMainFailure(message: message) { [weak store] in
                Task { await store?.reload() }
            }
        }
    }

    private func presentMainWindow() {
        presentMainContent(
            WorkspaceView(
                store: store,
                onOpenSettings: { [weak self] in self?.presentSettingsWindow() },
                onOpenDiagnostics: { [weak self] destination in
                    self?.presentDiagnosticsWindow(destination)
                },
                onShowLogs: { [weak self] in self?.showLogsInFinder() }
            ),
            surface: .workspace,
            title: store.organization?.name ?? "Clumsies Lab"
        )
    }

    private func presentMainLoading() {
        presentMainContent(LaunchView(), surface: .loading, title: "Clumsies")
    }

    private func presentMainFailure(message: String, retry: @escaping () -> Void) {
        presentMainContent(
            FailureView(
                message: message,
                retry: retry,
                onShowLogs: { [weak self] in self?.showLogsInFinder() }
            ),
            surface: .failure,
            title: "Clumsies"
        )
    }

    private func presentMainContent<Content: View>(
        _ content: Content,
        surface: MainWindowSurface,
        title: String
    ) {
        let contentView = NSHostingView(rootView: content)
        if #available(macOS 26.0, *) {
            contentView.sceneBridgingOptions = .all
        }
        if let mainWindow {
            mainWindow.title = title
            mainWindow.contentView = contentView
            mainWindowSurface = surface
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        window.minSize = NSSize(width: 920, height: 600)
        window.setFrameAutosaveName("ClumsiesNativeWorkspaceWindow")
        if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            window.setContentSize(NSSize(width: 1280, height: 820))
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
        mainWindowSurface = surface
    }

    private func presentAuthenticationContent<Content: View>(_ content: Content) {
        let size = NSSize(width: 460, height: 480)
        let controller = NSHostingController(
            rootView: content.frame(width: size.width, height: size.height)
        )
        controller.preferredContentSize = size
        if let window = authenticationWindow {
            window.contentViewController = controller
            window.contentMinSize = size
            window.contentMaxSize = size
            window.setContentSize(size)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clumsies"
        window.contentViewController = controller
        window.contentMinSize = size
        window.contentMaxSize = size
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        authenticationWindow = window
    }

    private func presentSettingsWindow() {
        if let settingsWindow {
            let pane = (settingsWindow.contentViewController as? SettingsTabViewController)?
                .selectedPane ?? .general
            SettingsWindowLayout.normalize(settingsWindow, pane: pane)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let selectedPane = SettingsPane.restored()
        let items = SettingsPane.allCases.map { pane in
            let controller = NSHostingController(
                rootView: NativeSettingsView(
                    store: store,
                    softwareUpdateController: softwareUpdateController,
                    pane: pane,
                    onOpenDiagnostics: { [weak self] in
                        self?.presentDiagnosticsWindow(.runtime)
                    },
                    onShowLogs: { [weak self] in self?.showLogsInFinder() }
                )
            )
            controller.sizingOptions = []
            return (pane, controller as NSViewController)
        }
        let controller = SettingsTabViewController(items: items, selectedPane: selectedPane)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindowLayout.defaultContentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        SettingsWindowLayout.normalize(window, pane: selectedPane)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    private func presentDiagnosticsWindow(_ destination: DiagnosticsDestination) {
        let controller = NSHostingController(
            rootView: NativeDiagnosticsView(store: store, destination: destination)
        )
        controller.sizingOptions = []
        if let diagnosticsWindow {
            diagnosticsWindow.contentViewController = controller
            DiagnosticsWindowLayout.normalize(diagnosticsWindow, destination: destination)
            diagnosticsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: destination.defaultContentSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        DiagnosticsWindowLayout.normalize(window, destination: destination)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        diagnosticsWindow = window
    }

    @objc func showLogsInFinderAction(_ sender: Any?) {
        showLogsInFinder()
    }

    private func showLogsInFinder() {
        let path = store.runtime?.health.logDir
        let logURL: URL
        if let path, !path.isEmpty {
            logURL = URL(fileURLWithPath: path)
        } else {
            logURL = AppBundleRuntimeLocation.defaultLogDirectoryURL
        }
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        } else {
            NSWorkspace.shared.open(logURL)
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }
        let image = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Clumsies")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "Clumsies"
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let open = menu.addItem(
            withTitle: "Open Clumsies",
            action: #selector(openFromStatusItem(_:)),
            keyEquivalent: ""
        )
        open.target = self
        let settings = menu.addItem(
            withTitle: "Settings...",
            action: #selector(showSettings(_:)),
            keyEquivalent: ""
        )
        settings.target = self
        let revealLogs = menu.addItem(
            withTitle: "Reveal Logs in Finder",
            action: #selector(showLogsInFinderAction(_:)),
            keyEquivalent: ""
        )
        revealLogs.target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Clumsies",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        )
        return menu
    }

    private func restorePrimaryWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let authenticationWindow, authenticationWindow.isVisible {
            authenticationWindow.deminiaturize(nil)
            authenticationWindow.makeKeyAndOrderFront(nil)
            return
        }
        if let mainWindow, mainWindow.isVisible {
            mainWindow.deminiaturize(nil)
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }
        present(store.phase)
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusMenu.appearance = NSApp.effectiveAppearance
            statusMenu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.height),
                in: sender
            )
            return
        }
        restorePrimaryWindow()
    }

    @objc private func openFromStatusItem(_ sender: Any?) {
        restorePrimaryWindow()
    }

    private func installApplicationMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        mainMenu.addItem(applicationItem)
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "About Clumsies", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        let settings = applicationMenu.addItem(withTitle: "Settings...", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        let updates = applicationMenu.addItem(withTitle: "Check for Updates...", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updates.target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Hide Clumsies", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        applicationMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Quit Clumsies", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        let newMemory = fileMenu.addItem(withTitle: "New Memory", action: #selector(newMemory(_:)), keyEquivalent: "n")
        newMemory.target = self
        let newProject = fileMenu.addItem(
            withTitle: "New Project…",
            action: #selector(newProject(_:)),
            keyEquivalent: "n"
        )
        newProject.keyEquivalentModifierMask = [.command, .shift]
        newProject.target = self
        fileMenu.addItem(.separator())
        let closeTab = fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeActiveTab(_:)), keyEquivalent: "w")
        closeTab.target = self
        let closeWindow = fileMenu.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let find = editMenu.addItem(
            withTitle: "Find...",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: "f"
        )
        find.tag = 1
        let findNext = editMenu.addItem(
            withTitle: "Find Next",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: "g"
        )
        findNext.tag = 2
        let findPrevious = editMenu.addItem(
            withTitle: "Find Previous",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: "g"
        )
        findPrevious.tag = 3
        findPrevious.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        let search = editMenu.addItem(withTitle: "Search Clumsies...", action: #selector(showSearch(_:)), keyEquivalent: "k")
        search.target = self
        editItem.submenu = editMenu

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let sidebar = viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .option]
        sidebar.target = self
        viewItem.submenu = viewMenu

        let reviewItem = NSMenuItem()
        mainMenu.addItem(reviewItem)
        let reviewMenu = NSMenu(title: "Review")
        let approve = reviewMenu.addItem(
            withTitle: "Approve",
            action: #selector(approveReview(_:)),
            keyEquivalent: "a"
        )
        approve.keyEquivalentModifierMask = [.command, .option]
        approve.target = self
        let reject = reviewMenu.addItem(
            withTitle: "Reject",
            action: #selector(rejectReview(_:)),
            keyEquivalent: "r"
        )
        reject.keyEquivalentModifierMask = [.command, .option]
        reject.target = self
        reviewMenu.addItem(.separator())
        let merge = reviewMenu.addItem(
            withTitle: "Merge",
            action: #selector(mergeReview(_:)),
            keyEquivalent: "m"
        )
        merge.keyEquivalentModifierMask = [.command, .option]
        merge.target = self
        let resubmit = reviewMenu.addItem(
            withTitle: "Resubmit",
            action: #selector(resubmitReview(_:)),
            keyEquivalent: "u"
        )
        resubmit.keyEquivalentModifierMask = [.command, .option]
        resubmit.target = self
        reviewItem.submenu = reviewMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = mainMenu
    }

    @objc private func showSettings(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        presentSettingsWindow()
    }

    @objc private func newMemory(_ sender: Any?) {
        guard store.selectedSection == .memory else { return }
        Task { await store.createMemory(kind: store.selectedKind, scope: .org) }
    }

    @objc private func newProject(_ sender: Any?) {
        store.presentProjectCreation()
    }

    @objc private func closeActiveTab(_ sender: Any?) {
        if !store.closeActiveTab() {
            mainWindow?.performClose(sender)
        }
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        softwareUpdateController.checkForUpdates()
    }

    @objc private func showSearch(_ sender: Any?) {
        mainWindow?.makeKeyAndOrderFront(nil)
        switch store.selectedSection {
        case .issues:
            store.focusIssueSearch()
        case .reviews:
            store.focusReviewSearch()
        default:
            store.showsGlobalSearch = true
        }
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        store.sidebarExpanded.toggle()
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func approveReview(_ sender: Any?) {
        Task { await store.performReviewMenuAction(.approve) }
    }

    @objc private func rejectReview(_ sender: Any?) {
        Task { await store.performReviewMenuAction(.reject) }
    }

    @objc private func mergeReview(_ sender: Any?) {
        Task { await store.performReviewMenuAction(.merge) }
    }

    @objc private func resubmitReview(_ sender: Any?) {
        Task { await store.performReviewMenuAction(.resubmit) }
    }
}

private struct LaunchView: View {
    @State private var loadingStageText: String = "Connecting to resident daemon…"

    private let brandAccent = Color(red: 0.88, green: 0.32, blue: 0.60)

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                BrandLogoView(size: 68, isBreathing: true)

                VStack(spacing: 4) {
                    Text("Clumsies")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text("The Collaborative Memory Platform for Agent Coding")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(brandAccent)
                    .frame(width: 160)
                    .controlSize(.small)

                Text(loadingStageText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .onAppear {
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                withAnimation(.easeInOut(duration: 0.3)) {
                    loadingStageText = "Syncing team memory…"
                }
            }
        }
    }
}

private struct AuthenticationView: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            BrandLogoView(size: 76, isBreathing: false)
            VStack(spacing: 8) {
                Text("Sign in to Clumsies")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .tracking(0.3)
                Text("Continue with your organization's identity provider.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await store.signIn() }
            } label: {
                Text("Continue in Browser")
                    .fontWeight(.medium)
                    .frame(minWidth: 190)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Color(red: 0.78, green: 0.24, blue: 0.52))
            if let message = store.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            Spacer()
        }
        .padding(38)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }
}

private struct FailureView: View {
    let message: String
    let retry: () -> Void
    var onShowLogs: (() -> Void)?
    @State private var copied = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38))
                .foregroundStyle(.yellow)
            Text("Clumsies could not start local daemon")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(8)
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .frame(maxWidth: 520)

            HStack(spacing: 12) {
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)

                Button("Reveal Logs in Finder") {
                    if let onShowLogs {
                        onShowLogs()
                    } else {
                        let url = AppBundleRuntimeLocation.defaultLogDirectoryURL
                        if FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .buttonStyle(.bordered)

                Button(copied ? "Copied!" : "Copy Diagnostics") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    let report = """
                    Clumsies Startup Diagnostics:
                    Error: \(message)
                    Log Directory: \(AppBundleRuntimeLocation.defaultLogDirectoryURL.path)
                    """
                    pasteboard.setString(report, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(38)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
