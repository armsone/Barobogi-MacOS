import AppKit
import Carbon
import Combine
import Foundation

@MainActor
public final class AppInputLanguageStore: ObservableObject {
    @Published public var isEnabled: Bool {
        didSet { save() }
    }

    @Published public var rules: [AppInputLanguageRule] {
        didSet { save() }
    }

    @Published public var recoveryNotice: String?

    private let defaults: UserDefaults
    private let storageKey = "TrackpadGuard.appInputLanguageRules.v1"
    private let corruptedBackupKey = "TrackpadGuard.appInputLanguageRules.corruptedBackup"

    private struct PersistedData: Codable {
        var isEnabled: Bool
        var rules: [AppInputLanguageRule]
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey) {
            do {
                let decoded = try JSONDecoder().decode(PersistedData.self, from: data)
                self.isEnabled = decoded.isEnabled
                self.rules = decoded.rules
            } catch {
                if defaults.data(forKey: corruptedBackupKey) == nil {
                    defaults.set(data, forKey: corruptedBackupKey)
                    self.recoveryNotice = "앱별 입력 언어 설정을 읽지 못해 초기화했습니다. 이전 손상 데이터는 안전하게 백업되었습니다."
                } else {
                    self.recoveryNotice = "앱별 입력 언어 설정을 읽지 못해 초기화했습니다. 기존 손상 데이터 백업이 유지됩니다."
                }
                self.isEnabled = false
                self.rules = []
            }
        } else {
            self.isEnabled = false
            self.rules = []
        }
    }

    public func rule(for bundleID: String) -> AppInputLanguageRule? {
        rules.first { $0.bundleID == bundleID }
    }

    public func addOrUpdateRule(_ rule: AppInputLanguageRule) {
        if let index = rules.firstIndex(where: { $0.bundleID == rule.bundleID }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
    }

    public func addOrUpdateRules(_ newRules: [AppInputLanguageRule]) {
        var updated = rules
        for newRule in newRules {
            if let index = updated.firstIndex(where: { $0.bundleID == newRule.bundleID }) {
                updated[index] = newRule
            } else {
                updated.append(newRule)
            }
        }
        rules = updated
    }

    public func removeRule(bundleID: String) {
        rules.removeAll { $0.bundleID == bundleID }
    }

    public func removeRules(bundleIDs: Set<String>) {
        rules.removeAll { bundleIDs.contains($0.bundleID) }
    }

    public func updateInputSource(for bundleIDs: Set<String>, inputSourceID: String, inputSourceName: String) {
        var updated = rules
        for index in updated.indices {
            if bundleIDs.contains(updated[index].bundleID) {
                updated[index].inputSourceID = inputSourceID
                updated[index].inputSourceName = inputSourceName
            }
        }
        rules = updated
    }

    public func updateInputSource(for bundleID: String, inputSourceID: String, inputSourceName: String) {
        if let index = rules.firstIndex(where: { $0.bundleID == bundleID }) {
            rules[index].inputSourceID = inputSourceID
            rules[index].inputSourceName = inputSourceName
        }
    }

    public func dismissRecoveryNotice() {
        recoveryNotice = nil
    }

    private func save() {
        let payload = PersistedData(isEnabled: isEnabled, rules: rules)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: storageKey)
    }

    // MARK: - Carbon TIS Input Source Enumeration

    public static func installedInputSources() -> [InstalledInputSource] {
        guard let listRef = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else {
            return []
        }
        var sources: [InstalledInputSource] = []
        let keyboardCategory = kTISCategoryKeyboardInputSource as String

        for item in listRef as NSArray {
            let source = item as! TISInputSource

            // Check category
            if let categoryPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory) {
                let category = Unmanaged<CFString>.fromOpaque(categoryPtr).takeUnretainedValue() as String
                guard category == keyboardCategory else { continue }
            }

            // Must be selectable
            guard boolProperty(of: source, key: kTISPropertyInputSourceIsSelectCapable) else { continue }

            guard let id = inputSourceID(of: source) else { continue }
            let name = localizedName(of: source) ?? id

            if !sources.contains(where: { $0.inputSourceID == id }) {
                sources.append(InstalledInputSource(inputSourceID: id, localizedName: name))
            }
        }

        return sources.sorted {
            $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending
        }
    }

    public static func isInputSourceInstalled(_ inputSourceID: String) -> Bool {
        installedInputSources().contains { $0.inputSourceID == inputSourceID }
    }

    private static func inputSourceID(of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func localizedName(of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func boolProperty(of source: TISInputSource, key: CFString) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }
}
