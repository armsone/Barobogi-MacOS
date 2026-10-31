import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var overlay: OverlayPanelController!
    private let viewModel = AppViewModel()
    private let loginItem = LoginItemManager()
    private let updater = UpdaterManager()
    private var hotKey: GlobalHotKey?
    private var mailHotKey: GlobalHotKey?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        BundledFonts.registerIfNeeded()
        // 원화 환산 환율(번역과 별도): 저장 환율을 읽고, 연결 상태·앱 활성화를 지켜보며 뒤에서 갱신한다.
        ExchangeRateStore.shared.start()
        applyBundleIcon()
        buildMainMenu()

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 660, height: 400)
        let initialRegion = NSRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        ).integral
        overlay = OverlayPanelController(initialFrame: initialRegion, viewModel: viewModel)
        viewModel.attach(overlay: overlay)
        overlay.onWillHide = { [weak self] in self?.viewModel.windowWillHide() }
        viewModel.onHideRequested = { [weak self] in self?.overlay.hide() }

        buildStatusItem()

        let hotKey = GlobalHotKey { [weak self] in self?.showOverlay() }
        hotKey.register()
        self.hotKey = hotKey
        if !hotKey.isRegistered {
            viewModel.status = .error(hotKey.statusDescription)
        }

        // 선택한 메일 번역 전역 단축키(⌃⌥⇧⌘M). 화면 번역 단축키와 독립적으로 등록·실패 처리한다.
        // 이 앱을 앞으로 가져오기 전에 Mail의 선택 메시지를 먼저 읽는다(AppModel.translateSelectedMail).
        let mailHotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_M), id: GlobalHotKey.mailHotKeyID,
                                      display: GlobalHotKey.mailDisplayString) {
            AppModel.shared.translateSelectedMail()
        }
        mailHotKey.register()
        self.mailHotKey = mailHotKey

        // 메일 번역: Mail › 서비스 메뉴, Mail 위 번역 버튼(기본 켜짐)
        MailWindowCoordinator.shared.start()

        // InputMate 수명주기 시작 (이전은 Coordinator에서 관리)
        InputMateCoordinator.shared.start()
        // Mac 관리(BTN) 활성화 시 수명주기 시작
        BTNIntegration.shared.startIfEnabled()

        DockVisibilityStore.shared.applyInitial()
        loginItem.applyInitialDefaultIfNeeded()
        updater.start()
        // 브라우저 번역 엔진 연결(허용했거나 브라우저 도우미가 실행한 경우에만 연다)
        BrowserIntegration.shared.applicationDidLaunch()
        writeDiagnostics()

        // 모든 실행 경로(콜드/수동/로그인/브라우저)에서 화면 번역 창은 자동으로 띄우지 않는다.
        // 메뉴·단축키에서만 화면 번역 창을 연다. Dock/Finder 재실행도 숨김 상태를 유지한다.
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Finder/Dock 실행도 reopen으로 전달되므로 화면 번역 창을 자동으로 열지 않는다.
        return true
    }

    /// .eml·이미지 파일 열기(Finder '다음으로 열기', Dock 아이콘으로 끌어놓기)
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        AppModel.shared.open(url: url)
        AppModel.shared.showMainWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        InputMateCoordinator.shared.stop()
        BTNIntegration.shared.stop()
        BrowserIntegration.shared.applicationWillTerminate()
        viewModel.stop()
        AppModel.shared.closeDocument()
        hotKey?.unregister()
        mailHotKey?.unregister()
        overlay.stopMonitoring()
        overlay.hide()
    }

    // MARK: - 아이콘

    /// Info.plist의 CFBundleIconFile(AppIcon.icns)과 같은 리소스를 Dock 아이콘에도 명시적으로 적용한다.
    private func applyBundleIcon() {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
    }

    /// 앱 아이콘을 메뉴 막대 크기(18pt)로 축소한 이미지. 여백이 큰 전체 아이콘을 그대로 쓰면 다른
    /// 메뉴 막대 아이콘보다 작아 보이므로, 아이콘의 둥근 사각형 부분만 중앙 크롭해 꽉 채운다.
    private func menuBarIconImage() -> NSImage? {
        guard let icon = NSApp.applicationIconImage else { return nil }
        let size = NSSize(width: 18, height: 18)
        let cropInset: CGFloat = icon.size.width * 0.085 // AppIcon-source.png 실측 여백 비율과 동일
        let sourceRect = NSRect(x: cropInset, y: cropInset,
                                 width: icon.size.width - cropInset * 2,
                                 height: icon.size.height - cropInset * 2)
        let image = NSImage(size: size)
        image.lockFocus()
        icon.draw(in: NSRect(origin: .zero, size: size), from: sourceRect, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    // MARK: - 창 표시/숨김

    @objc func showOverlay() {
        overlay.show(activate: true)
    }

    @objc func toggleOverlay() {
        if overlay.isVisible {
            overlay.hide()
        } else {
            showOverlay()
        }
    }

    @objc func hideOverlay() {
        overlay.hide()
    }

    @objc private func performPrimaryAction() {
        if !overlay.isVisible { overlay.show(activate: true) }
        viewModel.performPrimaryAction()
    }

    // MARK: - 메뉴 막대 상태 항목

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            // 메뉴 막대 아이콘은 SF Symbol 대신 기존 디자인된 앱 아이콘을 그대로 축소해 쓴다(원본 색 유지).
            button.image = menuBarIconImage()
            button.toolTip = "HTT (화면 \(GlobalHotKey.displayString) · 메일 \(GlobalHotKey.mailDisplayString))"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
    }

    /// 메뉴를 열 때마다 현재 상태(창 표시, 주 버튼, 로그인 항목, 업데이트)로 다시 만든다.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menu.removeAllItems()

        menu.addItem(headerItem())
        menu.addItem(item("HTT 홈…", #selector(showHome), symbol: "house"))
        menu.addItem(.separator())

        // MARK: 번역
        let overlayVisible = overlay.isVisible
        let screenItem = item(overlayVisible ? "화면 번역 창 숨기기" : "화면 번역 창 열기", #selector(toggleOverlay),
                               symbol: "text.viewfinder")
        // 전역 단축키는 항상 '보이기'만 수행하므로, 숨기기로 바뀌는 상태에서는 단축키 표기를 붙이지 않는다.
        if !overlayVisible {
            applyKeyEquivalent(screenItem, GlobalHotKey.screenKeyEquivalent, GlobalHotKey.screenModifierMask)
        }
        menu.addItem(screenItem)

        let primary: NSMenuItem
        if viewModel.isExternalRunning {
            primary = item("외부 AI 번역 취소", #selector(cancelExternalTranslation), symbol: "xmark.circle")
            primary.isEnabled = true
        } else if viewModel.isProcessing {
            primary = item("선택 영역 번역 중…", nil, symbol: "camera.viewfinder")
            primary.isEnabled = false
        } else {
            let title = (viewModel.primaryAction == .showOriginal) ? "원문보기" : "선택 영역 번역"
            primary = item(title, #selector(performPrimaryAction), symbol: viewModel.primaryAction.systemImage)
            primary.isEnabled = true
        }
        menu.addItem(primary)

        if viewModel.status != .idle {
            menu.addItem(info(viewModel.status.koreanText))
        }

        let mailItem = item("Mail에서 선택한 메일 번역", #selector(translateSelectedMail), symbol: "envelope")
        applyKeyEquivalent(mailItem, GlobalHotKey.mailKeyEquivalent, GlobalHotKey.mailModifierMask)
        menu.addItem(mailItem)
        menu.addItem(item("메일 번역 창 열기", #selector(showMailWindow), symbol: "envelope.open"))
        menu.addItem(item("브라우저 번역 설정…", #selector(showBrowserSetup), symbol: "globe"))

        menu.addItem(.separator())

        // MARK: 입력 도우미
        let isInputEnabled = InputMateCoordinator.shared.settings.preferences.isEnabled
        let inputToggle = item(
            isInputEnabled ? "입력 도우미 끄기" : "입력 도우미 켜기",
            #selector(toggleInputMateEnabled),
            symbol: isInputEnabled ? "keyboard" : "pause.circle"
        )
        menu.addItem(inputToggle)
        menu.addItem(item("입력 도우미 설정…", #selector(showInputSettings), symbol: "keyboard.badge.ellipsis"))

        menu.addItem(.separator())

        // MARK: Mac 관리
        menu.addItem(item("Mac 상태·정리 항목 보기…", #selector(showMacManagement), symbol: "cpu"))
        menu.addItem(item("Mac 관리 설정…", #selector(showMacManagementSettings), symbol: "slider.horizontal.3"))

        menu.addItem(.separator())

        // MARK: 앱 설정·도움말
        menu.addItem(item("앱 설정…", #selector(showSettings), symbol: "gearshape"))
        menu.addItem(item("사용 방법…", #selector(showGuide), symbol: "questionmark.circle"))
        let status = item("권한·연결 상태", nil, symbol: "info.circle")
        status.submenu = statusMenu()
        menu.addItem(status)

        menu.addItem(.separator())
        if let warning = actionNeededWarningItem() {
            menu.addItem(warning)
        }
        menu.addItem(item("HTT 정보", #selector(showAbout), symbol: "info.circle"))
        menu.addItem(item("업데이트 확인…", #selector(checkForUpdates), symbol: "arrow.down.circle"))
        menu.addItem(item("HTT 종료", #selector(NSApplication.terminate(_:)), target: NSApp, symbol: "power"))
    }

    /// 앱 아이콘·이름·버전을 보여주는 비활성 머리글 행
    private func headerItem() -> NSMenuItem {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let title = version.isEmpty ? "HTT" : "HTT v\(version)"
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        if let icon = NSApp.applicationIconImage {
            let resized = NSImage(size: NSSize(width: 18, height: 18))
            resized.lockFocus()
            icon.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            resized.unlockFocus()
            header.image = resized
            if #available(macOS 27.0, *) {
                header.preferredImageVisibility = .visible
            }
        }
        return header
    }

    /// 실패·조치 필요 상태만 눈에 띄게 올린다(정상일 때는 표시하지 않는다).
    private func actionNeededWarningItem() -> NSMenuItem? {
        let hotKeyFailed = hotKey?.isRegistered == false || mailHotKey?.isRegistered == false
        let loginNeedsApproval = loginItem.status == .requiresApproval
        let inputNeedsAccessibility = InputMateCoordinator.shared.settings.preferences.isEnabled &&
            InputMateCoordinator.shared.appState.serviceStatus == .needsAccessibility
        guard hotKeyFailed || loginNeedsApproval || inputNeedsAccessibility else { return nil }

        if inputNeedsAccessibility {
            let warning = item("입력 도우미 손쉬운 사용 권한 필요", #selector(openAccessibilitySettings), symbol: "exclamationmark.triangle")
            warning.isEnabled = true
            return warning
        }

        let text = hotKeyFailed ? "단축키 등록 실패 — 앱 상태 확인" : "로그인 항목 승인 필요"
        let warning = item(text, hotKeyFailed ? nil : #selector(openLoginItemsSettings), symbol: "exclamationmark.triangle")
        warning.isEnabled = !hotKeyFailed
        return warning
    }

    /// 단축키 등록, 로그인 항목, 업데이트의 세부 진단 텍스트(평상시 숨겨둠)
    private func statusMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(info("화면 번역 단축키: \(hotKey?.statusDescription ?? "없음")"))
        submenu.addItem(info("메일 번역 단축키: \(mailHotKey?.statusDescription ?? "없음")"))
        submenu.addItem(.separator())
        submenu.addItem(info("로그인 항목: \(loginItem.lastError ?? loginItem.statusDescription)"))
        if loginItem.status == .requiresApproval {
            submenu.addItem(item("로그인 항목 설정 열기…", #selector(openLoginItemsSettings), symbol: nil))
        }
        submenu.addItem(.separator())
        submenu.addItem(info("입력 도우미: \(InputMateCoordinator.shared.appState.statusText)"))
        if case .needsAccessibility = InputMateCoordinator.shared.appState.serviceStatus {
            submenu.addItem(item("손쉬운 사용 권한 설정 열기…", #selector(openAccessibilitySettings), symbol: nil))
        }
        submenu.addItem(.separator())
        submenu.addItem(info("Mac 관리: \(BTNIntegration.shared.statusSummary)"))
        submenu.addItem(.separator())
        submenu.addItem(info("업데이트: \(updater.lastCheckResult ?? updater.statusDescription)"))
        let auto = item("자동 업데이트", #selector(toggleAutomaticUpdates), symbol: nil)
        auto.isEnabled = updater.isAvailable
        auto.state = updater.automaticallyUpdates ? .on : .off
        submenu.addItem(auto)
        return submenu
    }

    private func item(_ title: String, _ action: Selector?, target: AnyObject? = nil, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : (target ?? self)
        item.isEnabled = true
        if let symbol {
            item.image = symbolImage(symbol)
            if #available(macOS 27.0, *) {
                item.preferredImageVisibility = .visible
            }
        }
        return item
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func symbolImage(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    /// 전역 단축키(⌃⌥⇧⌘)와 같은 글자·보조키를 메뉴에도 그대로 보여준다(실제 단축키 의미를 바꾸지 않음).
    private func applyKeyEquivalent(_ item: NSMenuItem, _ key: String, _ mask: NSEvent.ModifierFlags) {
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = mask
    }

    @objc private func translateSelectedMail() {
        AppModel.shared.translateSelectedMail()
    }

    @objc private func showMailWindow() {
        AppModel.shared.showMainWindow()
    }

    @objc private func openMailFile() {
        AppModel.shared.showMainWindow()
        AppModel.shared.showImporter = true
    }

    @objc private func clearMailDocument() {
        AppModel.shared.closeDocument()
    }

    @objc private func toggleMailToolbarButton() {
        if MailToolbarButton.shared.isEnabled {
            MailToolbarButton.shared.disable()
        } else {
            MailToolbarButton.shared.enable()
        }
    }

    @objc private func showHome() {
        MailWindowCoordinator.shared.showSettings(section: .home)
    }

    @objc private func showGuide() {
        MailWindowCoordinator.shared.showSettings(section: .help)
    }

    @objc private func showSettings() {
        MailWindowCoordinator.shared.showSettings(section: .general)
    }

    @objc private func showBrowserSetup() {
        MailWindowCoordinator.shared.showSettings(section: .browser)
    }

    @objc private func showInputSettings() {
        MailWindowCoordinator.shared.showSettings(section: .input)
    }

    @objc private func showMacManagement() {
        BTNIntegration.shared.showDetailWindow()
    }

    @objc private func showMacManagementSettings() {
        MailWindowCoordinator.shared.showSettings(section: .macManagement)
    }

    @objc private func toggleInputMateEnabled() {
        InputMateCoordinator.shared.toggleEnabled()
    }

    @objc private func openAccessibilitySettings() {
        InputMateCoordinator.shared.appState.requestAccessibilityAndRetry()
    }

    @objc private func cancelExternalTranslation() {
        viewModel.cancelExternalTranslation()
    }

    /// ⌘W: 메일·설정·AI 브라우저 창이 앞에 있으면 그 창을 닫고, 아니면 화면 번역 창을 숨긴다.
    @objc private func closeFrontWindow() {
        if let key = NSApp.keyWindow, key !== overlay.panel, key.styleMask.contains(.closable) {
            key.performClose(nil)
        } else {
            overlay.hide()
        }
    }

    @objc private func openLoginItemsSettings() {
        loginItem.openSystemSettings()
    }

    @objc func checkForUpdates() {
        updater.checkForUpdates()
    }

    @objc private func toggleAutomaticUpdates() {
        updater.setAutomaticallyUpdates(!updater.automaticallyUpdates)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    // MARK: - 앱 메뉴

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(item("HTT 홈…", #selector(showHome), symbol: "house"))
        appMenu.addItem(item("HTT 정보", #selector(showAbout)))
        appMenu.addItem(item("업데이트 확인…", #selector(checkForUpdates)))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Mac 상태·정리 항목 보기…", #selector(showMacManagement)))
        let settings = NSMenuItem(title: "앱 설정…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        let browserSettings = NSMenuItem(title: "브라우저 번역 설정…", action: #selector(showBrowserSetup), keyEquivalent: "")
        browserSettings.target = self
        appMenu.addItem(browserSettings)
        let inputSettings = NSMenuItem(title: "입력 도우미 설정…", action: #selector(showInputSettings), keyEquivalent: "")
        inputSettings.target = self
        appMenu.addItem(inputSettings)
        let macSettings = NSMenuItem(title: "Mac 관리 설정…", action: #selector(showMacManagementSettings), keyEquivalent: "")
        macSettings.target = self
        appMenu.addItem(macSettings)
        let guide = NSMenuItem(title: "사용 방법…", action: #selector(showGuide), keyEquivalent: "")
        guide.target = self
        appMenu.addItem(guide)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "HTT 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 메일 번역(원래 메일 번역기의 파일 메뉴 항목)
        let mailMenuItem = NSMenuItem()
        let mailMenu = NSMenu(title: "메일")
        let translateMail = NSMenuItem(title: "Mail에서 선택한 메일 번역", action: #selector(translateSelectedMail), keyEquivalent: "t")
        translateMail.keyEquivalentModifierMask = [.command, .shift]
        translateMail.target = self
        mailMenu.addItem(translateMail)
        let openFile = NSMenuItem(title: "파일 열기…", action: #selector(openMailFile), keyEquivalent: "o")
        openFile.target = self
        mailMenu.addItem(openFile)
        mailMenu.addItem(item("메일 번역 창 열기", #selector(showMailWindow)))
        mailMenu.addItem(.separator())
        mailMenu.addItem(item("Mail 위 번역 버튼 켜기/끄기", #selector(toggleMailToolbarButton)))
        mailMenu.addItem(.separator())
        let clear = NSMenuItem(title: "현재 내용 지우기", action: #selector(clearMailDocument), keyEquivalent: String(UnicodeScalar(NSBackspaceCharacter)!))
        clear.keyEquivalentModifierMask = [.command]
        clear.target = self
        mailMenu.addItem(clear)
        mailMenuItem.submenu = mailMenu
        mainMenu.addItem(mailMenuItem)

        // 편집: 메일 결과의 텍스트 선택·복사, 외부 AI 로그인 창 입력, 수동 응답 붙여넣기에 필요하다.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "편집")
        editMenu.addItem(NSMenuItem(title: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "윈도우")
        let show = NSMenuItem(title: "화면 번역 창 열기", action: #selector(showOverlay), keyEquivalent: "0")
        show.target = self
        windowMenu.addItem(show)
        let hide = NSMenuItem(title: "화면 번역 창 숨기기", action: #selector(hideOverlay), keyEquivalent: "")
        hide.target = self
        windowMenu.addItem(hide)
        let close = NSMenuItem(title: "창 닫기", action: #selector(closeFrontWindow), keyEquivalent: "w")
        close.target = self
        windowMenu.addItem(close)
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "도움말")
        helpMenu.addItem(item("사용 방법…", #selector(showGuide)))
        helpMenu.addItem(item("HTT 정보", #selector(showAbout)))
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    // MARK: - 진단 로그 (비밀 정보 없음)

    /// 설치 경로, 버전, 로그인 항목/단축키/업데이터/번역 방식 이름만 기록한다. 화면·메일 내용과 텍스트는 기록하지 않는다.
    private func writeDiagnostics() {
        let info = Bundle.main.infoDictionary ?? [:]
        let lines = [
            "time=\(ISO8601DateFormatter().string(from: Date()))",
            "version=\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))",
            "bundleIdentifier=\(Bundle.main.bundleIdentifier ?? "?")",
            "bundlePath=\(Bundle.main.bundlePath)",
            "executable=\(Bundle.main.executablePath ?? "?")",
            "loginItemStatus=\(loginItem.status.rawValue) \(loginItem.statusDescription)",
            "loginItemPreference=\(loginItem.preference.map { String($0) } ?? "unset")",
            "loginItemError=\(loginItem.lastError ?? "none")",
            "hotKey=\(hotKey?.statusDescription ?? "none")",
            "mailHotKey=\(mailHotKey?.statusDescription ?? "none")",
            "mailToolbarButton=\(MailToolbarButton.shared.isEnabled)",
            "translationBackend=\(TranslationBackendStore.shared.backend.rawValue)",
            "browserBridgeEnabled=\(BrowserIntegration.shared.isEnabled) launchedByBrowser=\(BrowserIntegration.shared.launchedByBrowser)",
            "updater=\(updater.statusDescription)",
            "feedURL=\(info["SUFeedURL"] as? String ?? "none")",
            "publicKeyPresent=\(!((info["SUPublicEDKey"] as? String) ?? "").isEmpty)"
        ]
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ScreenTranslator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("diagnostics.log"), atomically: true, encoding: .utf8)
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// '현재 내용 지우기'(⌘⌫)는 메일 번역 창이 앞에 있을 때만 동작한다(다른 창의 입력 중 실수로 지우지 않게).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(clearMailDocument) {
            return NSApp.keyWindow.map { MailWindowCoordinator.shared.isMailWindow($0) } ?? false
        }
        return true
    }
}
