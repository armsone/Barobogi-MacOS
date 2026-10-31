import SwiftUI

/// HTT 1.0.0 통합 워크벤치 네비게이션 섹션.
/// 홈, 번역·브라우저, 입력 도우미, Mac 관리, 사용 방법, 앱 설정으로 구성된다.
public enum SettingsSection: Hashable, CaseIterable, Identifiable {
    case home
    case browser
    case input
    case macManagement
    case help
    case general

    public var id: Self { self }

    public var title: String {
        switch self {
        case .home: return "홈"
        case .browser: return "번역·브라우저"
        case .input: return "입력 도우미"
        case .macManagement: return "Mac 관리"
        case .help: return "사용 방법"
        case .general: return "앱 설정"
        }
    }

    public var iconId: String {
        switch self {
        case .home: return "home"
        case .browser: return "browser"
        case .input: return "edit"
        case .macManagement: return "device_files"
        case .help: return "help"
        case .general: return "settings"
        }
    }
}

/// 설정 창이 열려 있는 동안 메뉴 막대에서 다시 "브라우저 번역…" 등을 눌러도 같은 창에서 탭만 바꾼다.
@MainActor
public final class SettingsSectionStore: ObservableObject {
    @Published public var section: SettingsSection = .home
    /// 창이 처음 만들어지기 전의 요청도 보존하며, 시트를 닫으면 바인딩이 다시 false로 바뀐다.
    @Published public var showLanguagePackSheet = false

    public init(section: SettingsSection = .home) {
        self.section = section
    }
}

/// HTT 1.0.0 통합 워크벤치 뷰 (SettingsView).
/// 네이티브 사이드바 및 상세 영역 구조로 모든 기능과 설정, 사용 방법을 한 창에서 제공한다.
public struct SettingsView: View {
    @ObservedObject public var store: SettingsSectionStore
    @ObservedObject private var appearance = HTTAppearanceStore.shared
    @Environment(\.colorScheme) private var systemColorScheme

    public init(store: SettingsSectionStore) {
        self.store = store
    }

    private var palette: HTTThemePalette {
        appearance.palette(for: systemColorScheme)
    }

    public var body: some View {
        NavigationSplitView {
            sidebarView
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
        } detail: {
            detailView
        }
        .frame(minWidth: 760, idealWidth: 900, maxWidth: .infinity,
               minHeight: 560, idealHeight: 700, maxHeight: .infinity)
        .preferredColorScheme(appearance.effectiveColorScheme(for: systemColorScheme))
    }

    // MARK: - 사이드바 (Sidebar)

    private var sidebarView: some View {
        VStack(spacing: 0) {
            List(SettingsSection.allCases, id: \.self, selection: Binding(
                get: { store.section },
                set: { if let newSection = $0 { store.section = newSection } }
            )) { section in
                NavigationLink(value: section) {
                    Label {
                        Text(section.title)
                            .font(.body)
                    } icon: {
                        HTTIconView(id: section.iconId, size: 18)
                    }
                }
                .tag(section)
            }
            .listStyle(.sidebar)

            Divider()

            HStack {
                HTTThemeButton()
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    .font(.caption2)
                    .foregroundStyle(palette.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(palette.card)
        }
        .background(palette.card)
    }

    // MARK: - 상세 영역 (Detail View)

    @ViewBuilder
    private var detailView: some View {
        Group {
            switch store.section {
            case .home:
                HTTHomeView(settingsStore: store)
            case .browser:
                BrowserSetupView(settingsStore: store)
            case .input:
                InputMateSettingsView()
            case .macManagement:
                BTNSettingsView(integration: .shared)
            case .help:
                HTTGuideView(settingsStore: store)
            case .general:
                AISettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bg)
    }
}
