import AppKit
import Combine
import SwiftUI

private enum MainWindowSurface: Equatable {
    case loading
    case workspace
    case failure
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
    private var isFlushingForTermination = false
    private var mainWindowSurface: MainWindowSurface?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installApplicationMenu()
        observePhase()
        NSApp.activate(ignoringOtherApps: true)
        store.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
        if menuItem.action == #selector(newMemory(_:)) {
            guard store.selectedSection == .hub || store.selectedSection == .local else { return false }
            let scope: MemoryScope = store.selectedSection == .hub ? .org : .project
            return store.canCreateMemory(kind: store.selectedKind, scope: scope)
        }
        if menuItem.action == #selector(closeActiveTab(_:)) {
            return store.activeVisibleTab != nil
        }
        if menuItem.action == #selector(toggleSidebar(_:)) {
            menuItem.title = store.sidebarExpanded ? "Hide Sidebar" : "Show Sidebar"
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
                onOpenDiagnostics: { [weak self] in self?.presentDiagnosticsWindow() }
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
            FailureView(message: message, retry: retry),
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
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(
            rootView: NativeSettingsView(
                store: store,
                softwareUpdateController: softwareUpdateController,
                onOpenDiagnostics: { [weak self] in self?.presentDiagnosticsWindow() }
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 470),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentViewController = controller
        window.minSize = NSSize(width: 520, height: 400)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    private func presentDiagnosticsWindow() {
        if let diagnosticsWindow {
            diagnosticsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: NativeDiagnosticsView(store: store))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Diagnostics"
        window.contentViewController = controller
        window.minSize = NSSize(width: 560, height: 440)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        diagnosticsWindow = window
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
        presentSettingsWindow()
    }

    @objc private func newMemory(_ sender: Any?) {
        guard store.selectedSection == .hub || store.selectedSection == .local else { return }
        let scope: MemoryScope = store.selectedSection == .hub ? .org : .project
        Task { await store.createMemory(kind: store.selectedKind, scope: scope) }
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
        store.showsGlobalSearch = true
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        store.sidebarExpanded.toggle()
        mainWindow?.makeKeyAndOrderFront(nil)
    }
}

private struct LaunchView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
            ProgressView()
                .controlSize(.small)
            Text("Opening workspace")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

private struct AuthenticationView: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 7) {
                Text("Sign in to Clumsies")
                    .font(.title2.weight(.semibold))
                Text("Continue with your organization's identity provider.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await store.signIn() }
            } label: {
                Text("Continue in Browser")
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
        .background(.background)
    }
}

private struct FailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Clumsies could not open")
                .font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(38)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
