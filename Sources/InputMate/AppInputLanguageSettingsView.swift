import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

struct AppInputLanguageSettingsView: View {
    @EnvironmentObject private var store: AppInputLanguageStore
    @State private var installedSources: [InstalledInputSource] = []
    @State private var selectedRuleIDs = Set<String>()
    @State private var batchSourceID = ""
    @State private var showingAddSheet = false
    @State private var pendingCandidates: [CandidateApp] = []
    @State private var selectedSourceForPending = ""
    @State private var sheetErrorMessage: String?

    struct CandidateApp: Identifiable, Hashable {
        var id: String { bundleID }
        let bundleID: String
        let displayName: String
        let icon: NSImage
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection

                if let notice = store.recoveryNotice {
                    recoveryBanner(notice)
                }

                actionBar

                if !selectedRuleIDs.isEmpty {
                    batchActionBar
                }

                rulesSection
            }
            .padding(20)
        }
        .onAppear {
            refreshInstalledSources()
        }
        .sheet(isPresented: $showingAddSheet) {
            addCandidatesSheet
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("앱별 기본 입력 언어 자동 전환", isOn: $store.isEnabled)
                .font(.headline)
            Text("선택한 앱으로 전환할 때 지정한 입력 소스(영어, 한글 등)로 자동 변경합니다. 앱 안에서 수동으로 변경한 언어는 다른 앱으로 전환할 때까지 유지됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Recovery Banner

    private func recoveryBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("확인") { store.dismissRecoveryNotice() }
                .accessibilityLabel("복구 알림 닫기")
        }
        .padding(10)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                selectAppsFromOpenPanel()
            } label: {
                Label("앱 추가…", systemImage: "plus.circle.fill")
            }
            .disabled(!store.isEnabled)
            .accessibilityLabel("입력 언어를 설정할 앱 추가")

            if let quickApps = availableQuickExamples(), !quickApps.isEmpty {
                Menu {
                    ForEach(quickApps, id: \.bundleID) { example in
                        let target = example.isKorean ? findKoreanSource() : findEnglishSource()
                        Button {
                            addQuickExample(example)
                        } label: {
                            if target != nil {
                                Text("\(example.displayName) (\(example.suggestedLanguageName)) 추가")
                            } else {
                                Text("\(example.displayName) (\(example.suggestedLanguageName) - 입력 소스 미설치)")
                            }
                        }
                        .disabled(target == nil)
                    }

                    if quickApps.contains(where: { ($0.isKorean ? findKoreanSource() : findEnglishSource()) == nil }) {
                        Divider()
                        Text("필요한 입력 소스는 시스템 설정 > 키보드 > 텍스트 입력에서 추가할 수 있습니다.")
                    }
                } label: {
                    Label("자주 쓰는 앱 빠른 추가", systemImage: "sparkles")
                }
                .disabled(!store.isEnabled)
            }

            Spacer()

            Button {
                refreshInstalledSources()
            } label: {
                Label("입력 소스 새로고침", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("시스템 설치 입력 소스 목록 새로고침")
        }
    }

    // MARK: - Batch Action Bar

    private var batchActionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("\(selectedRuleIDs.count)개 앱 선택됨")
                    .font(.subheadline.bold())

                Spacer()

                Button("선택 해제") {
                    selectedRuleIDs.removeAll()
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Button(role: .destructive) {
                    store.removeRules(bundleIDs: selectedRuleIDs)
                    selectedRuleIDs.removeAll()
                } label: {
                    Label("선택 삭제", systemImage: "trash")
                }
            }

            HStack(spacing: 8) {
                Picker("일괄 변경:", selection: $batchSourceID) {
                    Text("입력 소스 선택").tag("")
                    ForEach(installedSources) { source in
                        Text(source.localizedName).tag(source.inputSourceID)
                    }
                }
                .frame(maxWidth: 240)

                Button("적용") {
                    applyBatchSource()
                }
                .disabled(batchSourceID.isEmpty || !installedSources.contains(where: { $0.inputSourceID == batchSourceID }))
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Rules Section

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("설정된 앱 목록")
                    .font(.subheadline.bold())
                Spacer()
                Text("\(store.rules.count)개 앱")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.rules.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("등록된 앱이 없습니다.")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("상단의 '앱 추가…' 버튼을 눌러 터미널, 카카오톡, ChatGPT 등의 기본 입력 언어를 지정하세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 6) {
                    ForEach(store.rules) { rule in
                        ruleRow(rule)
                    }
                }
            }
        }
    }

    private func ruleRow(_ rule: AppInputLanguageRule) -> some View {
        let isSelected = selectedRuleIDs.contains(rule.bundleID)
        let isSourceInstalled = installedSources.contains { $0.inputSourceID == rule.inputSourceID }

        return HStack(spacing: 12) {
            Toggle(isOn: Binding(
                get: { isSelected },
                set: { checked in
                    if checked {
                        selectedRuleIDs.insert(rule.bundleID)
                    } else {
                        selectedRuleIDs.remove(rule.bundleID)
                    }
                }
            )) {
                EmptyView()
            }
            .labelsHidden()
            .accessibilityLabel("\(rule.displayName) 선택 토글")

            Image(nsImage: icon(for: rule.bundleID))
                .resizable()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.displayName)
                    .font(.headline)
                    .help(rule.bundleID)

                if !isSourceInstalled {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("설치되지 않은 입력 소스 ('\(rule.inputSourceName)') - 다른 언어로 변경해 주세요")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            Picker(
                "입력 소스",
                selection: Binding(
                    get: { rule.inputSourceID },
                    set: { newID in
                        let name = installedSources.first { $0.inputSourceID == newID }?.localizedName ?? rule.inputSourceName
                        store.updateInputSource(for: rule.bundleID, inputSourceID: newID, inputSourceName: name)
                    }
                )
            ) {
                if !isSourceInstalled {
                    Text("\(rule.inputSourceName) (미설치)").tag(rule.inputSourceID)
                }
                ForEach(installedSources) { source in
                    Text(source.localizedName).tag(source.inputSourceID)
                }
            }
            .frame(width: 170)
            .labelsHidden()
            .accessibilityLabel("\(rule.displayName)의 기본 입력 언어")

            Button(role: .destructive) {
                store.removeRule(bundleID: rule.bundleID)
                selectedRuleIDs.remove(rule.bundleID)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(rule.displayName) 규칙 삭제")
        }
        .padding(10)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.12)
                : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    // MARK: - Add Sheet

    private var addCandidatesSheet: some View {
        VStack(spacing: 16) {
            Text("\(pendingCandidates.count)개 앱에 적용할 입력 언어 선택")
                .font(.headline)

            Text("선택한 모든 앱으로 전환할 때 사용할 기본 입력 소스를 선택하세요.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = sheetErrorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(pendingCandidates) { app in
                        HStack(spacing: 10) {
                            Image(nsImage: app.icon)
                                .resizable()
                                .frame(width: 24, height: 24)
                            Text(app.displayName)
                                .font(.body)
                                .help(app.bundleID)
                            Spacer()
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 180)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Text("기본 입력 소스:")
                Picker("입력 소스", selection: $selectedSourceForPending) {
                    ForEach(installedSources) { source in
                        Text(source.localizedName).tag(source.inputSourceID)
                    }
                }
                .labelsHidden()

                Button {
                    refreshInstalledSources()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("입력 소스 새로고침")
            }

            HStack {
                Button("취소") {
                    showingAddSheet = false
                    sheetErrorMessage = nil
                    pendingCandidates.removeAll()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("추가") {
                    applyPendingCandidates()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedSourceForPending.isEmpty || !installedSources.contains(where: { $0.inputSourceID == selectedSourceForPending }))
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    // MARK: - Helper Methods

    private func refreshInstalledSources() {
        installedSources = AppInputLanguageStore.installedInputSources()
        if !installedSources.contains(where: { $0.inputSourceID == batchSourceID }) {
            batchSourceID = installedSources.first?.inputSourceID ?? ""
        }
        if !installedSources.contains(where: { $0.inputSourceID == selectedSourceForPending }) {
            selectedSourceForPending = installedSources.first?.inputSourceID ?? ""
        }
    }

    private func selectAppsFromOpenPanel() {
        refreshInstalledSources()

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsOtherFileTypes = false
        panel.prompt = "선택"
        panel.title = "입력 언어를 지정할 앱 선택"

        if panel.runModal() == .OK {
            var candidates: [CandidateApp] = []
            var seenBundleIDs = Set<String>()
            for url in panel.urls {
                guard let bundle = Bundle(url: url),
                      let bundleID = bundle.bundleIdentifier else { continue }
                guard !seenBundleIDs.contains(bundleID) else { continue }
                seenBundleIDs.insert(bundleID)

                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")

                let icon = NSWorkspace.shared.icon(forFile: url.path)
                candidates.append(CandidateApp(bundleID: bundleID, displayName: name, icon: icon))
            }

            if !candidates.isEmpty {
                pendingCandidates = candidates
                sheetErrorMessage = nil
                if !installedSources.contains(where: { $0.inputSourceID == selectedSourceForPending }) {
                    selectedSourceForPending = installedSources.first?.inputSourceID ?? ""
                }
                showingAddSheet = true
            }
        }
    }

    private func applyPendingCandidates() {
        let capturedSourceID = selectedSourceForPending
        refreshInstalledSources()
        guard let source = installedSources.first(where: { $0.inputSourceID == capturedSourceID }) else {
            selectedSourceForPending = installedSources.first?.inputSourceID ?? ""
            sheetErrorMessage = "선택한 입력 소스를 시스템에서 찾을 수 없습니다. 목록을 새로고침했으니 다시 선택해 주세요."
            return
        }

        sheetErrorMessage = nil
        let newRules = pendingCandidates.map {
            AppInputLanguageRule(
                bundleID: $0.bundleID,
                displayName: $0.displayName,
                inputSourceID: source.inputSourceID,
                inputSourceName: source.localizedName
            )
        }
        store.addOrUpdateRules(newRules)
        pendingCandidates.removeAll()
        showingAddSheet = false
    }

    private func applyBatchSource() {
        guard !batchSourceID.isEmpty,
              let sourceName = installedSources.first(where: { $0.inputSourceID == batchSourceID })?.localizedName else {
            return
        }
        store.updateInputSource(for: selectedRuleIDs, inputSourceID: batchSourceID, inputSourceName: sourceName)
        selectedRuleIDs.removeAll()
    }

    private func icon(for bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }

    // MARK: - Quick Examples

    private struct QuickExample {
        let bundleID: String
        let displayName: String
        let isKorean: Bool
        var suggestedLanguageName: String { isKorean ? "한글" : "영어" }
    }

    private func availableQuickExamples() -> [QuickExample]? {
        let candidates: [(bundleID: String, defaultName: String, isKorean: Bool)] = [
            ("com.apple.Terminal", "터미널", false),
            ("com.googlecode.iterm2", "iTerm2", false),
            ("com.openai.codex", "Codex / ChatGPT", true),
            ("com.openai.chat", "ChatGPT", true),
            ("com.kakao.KakaoTalkMac", "카카오톡", true)
        ]

        var result: [QuickExample] = []
        for candidate in candidates {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate.bundleID),
                  !store.rules.contains(where: { $0.bundleID == candidate.bundleID }) else {
                continue
            }
            let resolvedName = resolvedDisplayName(for: candidate.bundleID, fallback: candidate.defaultName, at: url)
            result.append(QuickExample(bundleID: candidate.bundleID, displayName: resolvedName, isKorean: candidate.isKorean))
        }
        return result
    }

    private func resolvedDisplayName(for bundleID: String, fallback: String, at url: URL) -> String {
        if let bundle = Bundle(url: url) {
            if let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String),
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return name
            }
        }
        let fileDisplayName = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        if !fileDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fileDisplayName
        }
        return fallback
    }

    private func addQuickExample(_ example: QuickExample) {
        guard let source = example.isKorean ? findKoreanSource() : findEnglishSource() else { return }

        let rule = AppInputLanguageRule(
            bundleID: example.bundleID,
            displayName: example.displayName,
            inputSourceID: source.inputSourceID,
            inputSourceName: source.localizedName
        )
        store.addOrUpdateRule(rule)
    }

    private func findKoreanSource() -> InstalledInputSource? {
        let nonRomanSources = installedSources.filter {
            !$0.inputSourceID.hasSuffix(".Roman") && !$0.inputSourceID.contains(".Roman")
        }
        if let exact2Set = nonRomanSources.first(where: {
            $0.inputSourceID == "com.apple.inputmethod.Korean.2SetKorean"
                || $0.inputSourceID.hasSuffix(".2SetKorean")
        }) {
            return exact2Set
        }
        return nonRomanSources.first {
            $0.inputSourceID.hasPrefix("com.apple.inputmethod.Korean")
                || $0.localizedName.contains("한글")
                || $0.localizedName.contains("Korean")
        }
    }

    private func findEnglishSource() -> InstalledInputSource? {
        installedSources.first {
            $0.inputSourceID.hasPrefix("com.apple.keylayout.ABC")
                || $0.inputSourceID.hasPrefix("com.apple.keylayout.US")
                || $0.localizedName.contains("ABC")
                || $0.localizedName.contains("U.S.")
        }
    }
}
