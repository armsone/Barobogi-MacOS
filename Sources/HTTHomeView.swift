import AppKit
import SwiftUI

/// HTT 1.0.0 워크벤치 홈 뷰 (Home View).
/// 번역·입력 도우미·Mac 관리의 실제 상태를 한눈에 파악할 수 있도록 핵심 지표와 상태를 보여주고,
/// 각 기능으로의 즉각적인 조치 및 이동을 지원한다.
public struct HTTHomeView: View {
    @ObservedObject var settingsStore: SettingsSectionStore
    @EnvironmentObject private var inputSettings: SettingsStore
    @EnvironmentObject private var inputState: InputMateAppState
    @ObservedObject private var inputCoordinator = InputMateCoordinator.shared
    @ObservedObject private var btnIntegration = BTNIntegration.shared
    @ObservedObject private var appearance = HTTAppearanceStore.shared
    @Environment(\.colorScheme) private var colorScheme

    public init(settingsStore: SettingsSectionStore) {
        self.settingsStore = settingsStore
    }

    private var palette: HTTThemePalette {
        appearance.palette(for: colorScheme)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                glanceHeroBanner
                serviceStatusGrid
                quickAccessSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 핵심 상태 배너 (Glance Hero Banner)

    @ViewBuilder
    private var glanceHeroBanner: some View {
        if inputCoordinator.migrationFailed || btnIntegration.hasMigrationError {
            GroupBox {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(palette.danger)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("설정 데이터 확인 필요 — 안전을 위해 일부 기능 차단됨")
                            .font(.headline)
                            .foregroundStyle(palette.danger)
                        Text("기존 독립 앱의 설정 또는 보호 데이터 형식을 확인하지 못해 원본 데이터를 보호하기 위해 해당 모듈의 동작을 보류했습니다. 원본 데이터는 안전하게 보존되어 있습니다.")
                            .font(.callout)
                            .foregroundStyle(palette.text2)
                    }
                    Spacer()
                }
                .padding(10)
            }
        } else if inputSettings.preferences.isEnabled && inputState.serviceStatus == .needsAccessibility {
            GroupBox {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(palette.warn)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("입력 도우미 손쉬운 사용 권한 필요")
                            .font(.headline)
                        Text("한글 오타 교정 및 트랙패드 잠금 보호를 정상적으로 실행하려면 시스템 손쉬운 사용 권한이 필요합니다.")
                            .font(.callout)
                            .foregroundStyle(palette.text2)
                    }

                    Spacer()

                    Button("권한 설정 열기…") {
                        inputState.requestAccessibilityAndRetry()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                .padding(8)
            }
        } else if case let .unavailable(message) = inputState.serviceStatus, inputSettings.preferences.isEnabled {
            GroupBox {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(palette.danger)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("입력 도우미 서비스 사용 불가")
                            .font(.headline)
                            .foregroundStyle(palette.danger)
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(palette.text2)
                    }

                    Spacer()

                    Button("다시 시도") {
                        inputState.retry()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(8)
            }
        } else if inputCoordinator.isLegacyInputMateRunning || btnIntegration.isStandaloneConflictActive {
            GroupBox {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(palette.accent)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("독립 앱 실행 감지 — 충돌 방지 일시정지 중")
                            .font(.headline)
                        let details = [
                            inputCoordinator.isLegacyInputMateRunning ? "독립 InputMate" : nil,
                            btnIntegration.isStandaloneConflictActive ? "독립 BTN" : nil
                        ].compactMap { $0 }.joined(separator: ", ")
                        Text("\(details) 앱이 실행 중이어서 데이터 경합을 방지하기 위해 HTT 내 해당 모듈을 일시정지했습니다. 독립 앱 종료 시 자동 재개됩니다.")
                            .font(.callout)
                            .foregroundStyle(palette.text2)
                    }
                    Spacer()
                }
                .padding(8)
            }
        } else {
            GroupBox {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "app.badge.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(palette.accent)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("필요한 기능을 선택하세요")
                            .font(.headline)
                        Text("화면·메일·브라우저 번역, 입력 도우미, Mac 관리 기능을 아래 각 카드에서 상태를 확인하고 실행할 수 있습니다.")
                            .font(.callout)
                            .foregroundStyle(palette.text2)
                    }
                    Spacer()
                }
                .padding(8)
            }
        }
    }

    // MARK: - 3대 통합 모듈 상태 카드 그리드

    private var serviceStatusGrid: some View {
        VStack(spacing: 16) {
            translationCard
            inputHelperCard
            macManagementCard
        }
    }

    // 1. 번역·브라우저 카드
    private var translationCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HTTIconView(id: "browser", size: 24)
                    Text("번역 및 브라우저")
                        .font(.title3.bold())
                    Spacer()
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("화면 번역:")
                            .font(.subheadline.bold())
                        Text("투명 영역 캡처 후 원문 줄 위치에 즉시 번역 (전역 단축키 \(GlobalHotKey.displayString)으로 창 열기, 앱 내 ⌘0)")
                            .font(.subheadline)
                            .foregroundStyle(palette.text2)
                    }
                    HStack {
                        Text("메일 번역:")
                            .font(.subheadline.bold())
                        Text("Apple Mail 선택 메일 즉시 번역 (전역 단축키 \(GlobalHotKey.mailDisplayString), 앱 내 ⇧⌘T)")
                            .font(.subheadline)
                            .foregroundStyle(palette.text2)
                    }
                    HStack {
                        Text("브라우저:")
                            .font(.subheadline.bold())
                        Text("Chrome, Whale, Safari 웹페이지 및 이미지 실시간 번역 지원")
                            .font(.subheadline)
                            .foregroundStyle(palette.text2)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button("화면 번역 창 열기") {
                            (NSApp.delegate as? AppDelegate)?.showOverlay()
                        }
                        Button("Mail에서 선택한 메일 번역") {
                            AppModel.shared.translateSelectedMail()
                        }
                        Button("메일 번역 창 열기") {
                            AppModel.shared.showMainWindow()
                        }
                    }
                    HStack {
                        Spacer()
                        Button("브라우저 번역 설정…") {
                            settingsStore.section = .browser
                        }
                        .buttonStyle(.link)
                    }
                }
                .controlSize(.small)
            }
            .padding(8)
        }
    }

    // 2. 입력 도우미 카드
    private var inputHelperCard: some View {
        let isEnabled = inputSettings.preferences.isEnabled
        let status = inputState.serviceStatus
        let conflict = inputCoordinator.isLegacyInputMateRunning
        let migrationFailed = inputCoordinator.migrationFailed

        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HTTIconView(id: "edit", size: 24)
                    Text("입력 도우미")
                        .font(.title3.bold())
                    Spacer()
                    inputStatusBadge(isEnabled: isEnabled, status: status, conflict: conflict, migrationFailed: migrationFailed)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("설정 상태:")
                            .font(.subheadline.bold())
                        Text(isEnabled ? "입력 도우미 켜짐" : "입력 도우미 꺼짐")
                            .font(.subheadline)
                            .foregroundStyle(isEnabled ? palette.accentStrong : palette.muted)
                        Text("·")
                            .foregroundStyle(palette.muted)
                        Text("준비 상태:")
                            .font(.subheadline.bold())
                        Text(inputReadyDescription(isEnabled: isEnabled, status: status, conflict: conflict, migrationFailed: migrationFailed))
                            .font(.subheadline)
                            .foregroundStyle(palette.text2)
                    }
                    HStack {
                        Text("주요 기능:")
                            .font(.subheadline.bold())
                        Text("앱별 언어 전환, 한글 오타 교정, 첫 단어 복구, 단어 변환 및 한영 번역 (''), 줄 전체 번역 (\\\\, macOS 26+), 트랙패드 보호 (긴급 잠금 해제 ⌃⌥⌘⎋)")
                            .font(.subheadline)
                            .foregroundStyle(palette.text2)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button(isEnabled ? "입력 도우미 끄기" : "입력 도우미 켜기") {
                            inputCoordinator.toggleEnabled()
                        }
                        if isEnabled && status == .needsAccessibility {
                            Button("손쉬운 사용 권한 열기…") {
                                inputState.requestAccessibilityAndRetry()
                            }
                        }
                        if isEnabled, case .unavailable = status {
                            Button("다시 시도") {
                                inputState.retry()
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("입력 도우미 설정…") {
                            settingsStore.section = .input
                        }
                        .buttonStyle(.link)
                    }
                }
                .controlSize(.small)
            }
            .padding(8)
        }
    }

    // 3. Mac 관리 (BTN) 카드
    private var macManagementCard: some View {
        let isEnabled = btnIntegration.isManagementEnabled
        let isCleanup = btnIntegration.isCleanupEnabled
        let conflict = btnIntegration.isStandaloneConflictActive
        let migrationFailed = btnIntegration.hasMigrationError

        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HTTIconView(id: "device_files", size: 24)
                    Text("Mac 관리")
                        .font(.title3.bold())
                    Spacer()
                    macStatusBadge(isEnabled: isEnabled, isCleanup: isCleanup, conflict: conflict, migrationFailed: migrationFailed)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("모듈 상태:")
                            .font(.subheadline.bold())
                        Text(btnIntegration.statusSummary)
                            .font(.subheadline)
                            .foregroundStyle(palette.text2)
                    }
                    HStack {
                        Text("안전 원칙:")
                            .font(.subheadline.bold())
                        Text("점검 → 선택 → 최종 확인 → 휴지통 이동. 확인 전에는 파일을 삭제하지 않으며 휴지통으로 안전하게 이동합니다.")
                            .font(.subheadline)
                            .foregroundStyle(palette.text2)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button("Mac 상태·정리 항목 보기…") {
                            btnIntegration.showDetailWindow()
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Mac 관리 설정…") {
                            settingsStore.section = .macManagement
                        }
                        .buttonStyle(.link)
                    }
                }
                .controlSize(.small)
            }
            .padding(8)
        }
    }

    // MARK: - 빠른 바로가기 (Quick Access)

    private var quickAccessSection: some View {
        HStack(spacing: 14) {
            Button {
                settingsStore.section = .help
            } label: {
                HStack {
                    HTTIconView(id: "help", size: 18)
                    Text("사용 방법 안내 보기…")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)

            Button {
                settingsStore.section = .general
            } label: {
                HStack {
                    HTTIconView(id: "settings", size: 18)
                    Text("앱 설정 (테마·Dock·시작)…")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - 배지 및 상태 문구 헬퍼

    @ViewBuilder
    private func inputStatusBadge(isEnabled: Bool, status: InputMateAppState.ServiceStatus, conflict: Bool, migrationFailed: Bool) -> some View {
        if migrationFailed {
            badgeView(title: "이전 실패", bg: palette.dangerSoft, fg: palette.danger)
        } else if conflict {
            badgeView(title: "독립 앱 실행 중", bg: palette.warnSoft, fg: palette.warnInk)
        } else if !isEnabled {
            badgeView(title: "꺼짐", bg: Color.primary.opacity(0.08), fg: palette.muted)
        } else {
            switch status {
            case .off:
                badgeView(title: "꺼짐", bg: Color.primary.opacity(0.08), fg: palette.muted)
            case .needsAccessibility:
                badgeView(title: "권한 필요", bg: palette.warnSoft, fg: palette.warnInk)
            case .ready:
                badgeView(title: "준비됨", bg: palette.accentSoft, fg: palette.accentStrong)
            case .unavailable:
                badgeView(title: "사용 불가", bg: palette.dangerSoft, fg: palette.danger)
            }
        }
    }

    private func inputReadyDescription(isEnabled: Bool, status: InputMateAppState.ServiceStatus, conflict: Bool, migrationFailed: Bool) -> String {
        if migrationFailed {
            return "이전 확인 실패로 기능 중지됨 (원본 보호)"
        }
        if conflict {
            return "독립 InputMate 실행 중으로 자동 일시정지"
        }
        if !isEnabled {
            return "사용 안 함 (스위치 꺼짐)"
        }
        switch status {
        case .off:
            return "입력 서비스 꺼짐"
        case .needsAccessibility:
            return "손쉬운 사용 권한 승인 대기 중"
        case .ready:
            return "키보드 및 이벤트 감시 준비됨"
        case let .unavailable(message):
            return "사용 불가: \(message)"
        }
    }

    @ViewBuilder
    private func macStatusBadge(isEnabled: Bool, isCleanup: Bool, conflict: Bool, migrationFailed: Bool) -> some View {
        if migrationFailed {
            badgeView(title: "이전 실패", bg: palette.dangerSoft, fg: palette.danger)
        } else if conflict {
            badgeView(title: "독립 BTN 실행 중", bg: palette.warnSoft, fg: palette.warnInk)
        } else if !isEnabled {
            badgeView(title: "꺼짐", bg: Color.primary.opacity(0.08), fg: palette.muted)
        } else if !isCleanup {
            badgeView(title: "관찰 전용", bg: Color.primary.opacity(0.08), fg: palette.text2)
        } else {
            badgeView(title: "권장 모드", bg: palette.accentSoft, fg: palette.accentStrong)
        }
    }

    private func badgeView(title: String, bg: Color, fg: Color) -> some View {
        Text(title)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(bg, in: Capsule())
            .foregroundStyle(fg)
    }
}
