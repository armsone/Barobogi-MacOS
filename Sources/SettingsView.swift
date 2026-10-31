import SwiftUI

/// 설정·옵션·브라우저 번역·입력 도우미·Mac 관리를 한 창의 탭으로 모은다(별도 창을 여러 개 띄우지 않는다).
/// 메뉴 막대의 "설정…", "브라우저 번역…", "입력 설정…", "Mac 관리 설정…"은 같은 창을 열고 각자 맞는 탭만 고른다.
enum SettingsSection: Hashable {
    case general
    case browser
    case input
    case macManagement
}

/// 설정 창이 열려 있는 동안 메뉴 막대에서 다시 "브라우저 번역…" 등을 눌러도 같은 창에서 탭만 바꾼다.
@MainActor
final class SettingsSectionStore: ObservableObject {
    @Published var section: SettingsSection = .general
    /// 창이 처음 만들어지기 전의 요청도 보존하며, 시트를 닫으면 바인딩이 다시 false로 바뀐다.
    @Published var showLanguagePackSheet = false
}

struct SettingsView: View {
    @ObservedObject var store: SettingsSectionStore

    var body: some View {
        TabView(selection: $store.section) {
            AISettingsView()
                .tabItem { Label("일반", systemImage: "gearshape") }
                .tag(SettingsSection.general)
            BrowserSetupView(settingsStore: store)
                .tabItem { Label("브라우저 번역", systemImage: "globe") }
                .tag(SettingsSection.browser)
            InputMateSettingsView()
                .tabItem { Label("입력 도우미", systemImage: "keyboard") }
                .tag(SettingsSection.input)
            BTNSettingsView(integration: .shared)
                .tabItem { Label("Mac 관리", systemImage: "cpu") }
                .tag(SettingsSection.macManagement)
        }
        .frame(minWidth: store.section == .input ? 740 : (store.section == .macManagement ? 620 : 560),
               idealWidth: store.section == .input ? 760 : (store.section == .macManagement ? 640 : 560))
        .frame(minHeight: 640)
    }
}
