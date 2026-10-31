import AppKit
import Carbon
import Combine
import OSLog

@MainActor
final class AppInputLanguageController {
    private let store: AppInputLanguageStore
    private var cancellables = Set<AnyCancellable>()
    private var workspaceObserver: NSObjectProtocol?
    private var pendingSwitchTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.local.screentranslator", category: "AppInputLanguage")

    private(set) var isStarted: Bool = false
    private(set) var isSuspended: Bool = false

    init(store: AppInputLanguageStore) {
        self.store = store

        store.$isEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self, self.isStarted, !self.isSuspended else { return }
                if enabled {
                    Task { @MainActor [weak self] in
                        self?.applyToCurrentFrontmostApp()
                    }
                } else {
                    self.cancelPendingSwitch()
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        if workspaceObserver == nil {
            workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }
                Task { @MainActor in
                    self?.handleApplicationActivated(app)
                }
            }
        }

        if !isSuspended && store.isEnabled {
            applyToCurrentFrontmostApp()
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        cancelPendingSwitch()

        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
    }

    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        if suspended {
            cancelPendingSwitch()
        } else if isStarted && store.isEnabled {
            applyToCurrentFrontmostApp()
        }
    }

    func cancelPendingSwitch() {
        pendingSwitchTask?.cancel()
        pendingSwitchTask = nil
    }

    private func applyToCurrentFrontmostApp() {
        guard isStarted, !isSuspended, store.isEnabled else { return }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return }
        handleApplicationActivated(frontmost)
    }

    private func handleApplicationActivated(_ app: NSRunningApplication) {
        cancelPendingSwitch()

        guard isStarted, !isSuspended, store.isEnabled else { return }
        guard let bundleID = app.bundleIdentifier else { return }
        guard let rule = store.rule(for: bundleID) else { return }

        let targetPID = app.processIdentifier
        let targetBundleID = bundleID
        let expectedSourceID = rule.inputSourceID

        pendingSwitchTask = Task { @MainActor [weak self] in
            // Minimal bounded delay (25ms) allowing window manager focus transition
            try? await Task.sleep(nanoseconds: 25_000_000)
            guard !Task.isCancelled, let self else { return }

            guard self.isStarted, !self.isSuspended, self.store.isEnabled else { return }

            // Re-check frontmost process and bundle
            guard let currentFront = NSWorkspace.shared.frontmostApplication,
                  currentFront.processIdentifier == targetPID,
                  currentFront.bundleIdentifier == targetBundleID else {
                return
            }

            // Re-check rule still exists
            guard let currentRule = self.store.rule(for: targetBundleID),
                  currentRule.inputSourceID == expectedSourceID else {
                return
            }

            // Check if already active
            if let activeID = Self.currentInputSourceID(), activeID == expectedSourceID {
                return
            }

            // Attempt to select target input source; never fallback silently
            let success = Self.select(inputSourceID: expectedSourceID)
            if success {
                self.logger.info("Applied input source \(expectedSourceID, privacy: .public) to \(targetBundleID, privacy: .public)")
            } else {
                self.logger.warning("Target input source \(expectedSourceID, privacy: .public) could not be selected for \(targetBundleID, privacy: .public)")
            }
        }
    }

    static func currentInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    @discardableResult
    static func select(inputSourceID: String) -> Bool {
        guard let listRef = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return false }
        for item in listRef as NSArray {
            let source = item as! TISInputSource
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
            if id == inputSourceID {
                return TISSelectInputSource(source) == noErr
            }
        }
        return false
    }
}
