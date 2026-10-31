import Combine
import Foundation

// 성공한 수동 변환('')의 원문 → 결과 쌍을 이 Mac의 UserDefaults에만 저장한다. 로그·분석·클라우드 동기화는 쓰지 않는다.
// 키는 대소문자·철자를 그대로 비교하며, 값에는 공백이 들어갈 수 있다(예: 인명 표기).
@MainActor
public final class PersonalDictionaryStore: ObservableObject {
    public static let shared = PersonalDictionaryStore()

    private static let defaultsKey = "InputMate.personalDictionary"
    private static let seedKey = "InputMate.personalDictionarySeed.v1"

    @Published public private(set) var entries: [String: String]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 없거나 손상된 데이터는 빈 사전으로 시작하며 저장된 값을 지우지 않는다. 문자열 쌍만 읽는다.
        var loaded: [String: String] = [:]
        if let stored = defaults.dictionary(forKey: Self.defaultsKey) {
            for (key, value) in stored {
                if let text = value as? String, Self.isValid(source: key, replacement: text) {
                    loaded[key] = text
                }
            }
        }
        // 마이그레이션 실패 시에는 seed나 기본 항목으로 기존 사전을 덮어쓰거나 seed 마커를 쓰지 않는다.
        if !InputMateMigration.migrationFailed, !defaults.bool(forKey: Self.seedKey) {
            if loaded["한병기"] == nil || loaded["한병기"] == "Han Byeonggi" {
                loaded["한병기"] = "Han byoungki"
                defaults.set(loaded, forKey: Self.defaultsKey)
            }
            defaults.set(true, forKey: Self.seedKey)
        }
        entries = loaded
    }

    public func replacement(for source: String) -> String? {
        entries[source]
    }

    // 새 쌍만 추가한다. 이미 있는 항목(학습·사용자 수정)은 덮어쓰지 않으며, 실제로 추가했을 때만 true.
    @discardableResult
    public func remember(source: String, replacement: String) -> Bool {
        let value = Self.cleaned(replacement)
        guard Self.isValid(source: source, replacement: value), entries[source] == nil else { return false }
        entries[source] = value
        persist()
        return true
    }

    // 사용자가 직접 지정·수정한 값. 기존 항목은 덮어쓴다.
    public func set(source: String, replacement: String) {
        let value = Self.cleaned(replacement)
        guard Self.isValid(source: source, replacement: value), entries[source] != value else { return }
        entries[source] = value
        persist()
    }

    public func remove(source: String) {
        guard entries[source] != nil else { return }
        entries[source] = nil
        persist()
    }

    // 현재 값이 replacement와 같을 때만 지운다. 되돌리기로 방금 학습한 항목만 취소하는 용도다.
    public func removeIfMatching(source: String, replacement: String) {
        guard entries[source] == replacement else { return }
        remove(source: source)
    }

    private func persist() {
        guard !InputMateMigration.migrationFailed else { return }
        defaults.set(entries, forKey: Self.defaultsKey)
    }

    private static func cleaned(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isValid(source: String, replacement: String) -> Bool {
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !replacement.isEmpty
    }
}
