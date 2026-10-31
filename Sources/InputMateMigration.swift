import Foundation
import OSLog

/// 원본 com.armsone.TrackpadGuard의 설정과 개인 사전을 HTT(com.local.screentranslator)로 일회성 이전한다.
/// - 기존 HTT 값이 있으면 덮어쓰지 않고 우선한다.
/// - 원본 UserDefaults는 읽기만 하며 수정하거나 삭제하지 않는다.
/// - 알려진 키(설정 JSON, 앱별 언어 규칙, 손상 백업, 개인 사전 및 시드)만 이전하며 TCC, 로그인, 업데이터 등은 이전하지 않는다.
/// - 모든 이전 후보를 먼저 읽고 타입을 엄격하게 검증한 뒤 한 번에 복사하며, 손상/읽기 실패 시 부분 쓰기를 금지한다.
/// - 실제 사전 어휘나 입력 내용은 로그에 남기지 않는다.
enum InputMateMigration {
    private static let logger = Logger(subsystem: "com.local.screentranslator", category: "InputMateMigration")
    private static let migrationCompletedKey = "HTT.didMigrateInputMateSettings.v1"
    private static let sourceSuiteName = "com.armsone.TrackpadGuard"

    static let preferencesKey = "TrackpadGuard.preferences.v1"
    static let appLanguageRulesKey = "TrackpadGuard.appInputLanguageRules.v1"
    static let corruptedBackupKey = "TrackpadGuard.appInputLanguageRules.corruptedBackup"
    static let personalDictionaryKey = "InputMate.personalDictionary"
    static let personalDictionarySeedKey = "InputMate.personalDictionarySeed.v1"
    public private(set) static var migrationFailed: Bool = false

    private struct AppLanguageRulesPayload: Decodable {
        let isEnabled: Bool
        let rules: [AppInputLanguageRule]
    }

    @MainActor
    @discardableResult
    static func migrateIfNeeded(target: UserDefaults = .standard) -> Bool {
        if target.bool(forKey: migrationCompletedKey) {
            migrationFailed = false
            return true
        }

        let sourceDefaults = UserDefaults(suiteName: sourceSuiteName)

        func readSource(key: String) -> Any? {
            if let val = sourceDefaults?.object(forKey: key) {
                return val
            }
            if let cfVal = CFPreferencesCopyAppValue(key as CFString, sourceSuiteName as CFString) {
                return cfVal as Any
            }
            return nil
        }

        var candidatePreferences: Data?
        var candidateAppLanguageRules: Data?
        var candidateCorruptedBackup: Data?
        var candidateDictionary: [String: String]?
        var candidateSeed: Bool?

        // 1. GuardPreferences 이전 검증 (raw Data 보존 및 JSON 구조 검증)
        if let sourceVal = readSource(key: preferencesKey) {
            guard let data = sourceVal as? Data,
                  (try? JSONDecoder().decode(GuardPreferences.self, from: data)) != nil else {
                logger.error("InputMate migration failed: corrupted GuardPreferences JSON in source.")
                migrationFailed = true
                return false
            }
            candidatePreferences = data
        }

        // 2. AppInputLanguageStore 규칙 이전 검증 ({isEnabled, rules:[AppInputLanguageRule]} JSON 검증)
        if let sourceVal = readSource(key: appLanguageRulesKey) {
            guard let data = sourceVal as? Data,
                  (try? JSONDecoder().decode(AppLanguageRulesPayload.self, from: data)) != nil else {
                logger.error("InputMate migration failed: corrupted AppInputLanguageRules JSON in source.")
                migrationFailed = true
                return false
            }
            candidateAppLanguageRules = data
        }

        // 3. AppInputLanguageStore 손상 백업 보존 (손상백업은 opaque Data라 별도 JSON 디코드 검증 없음)
        if let sourceVal = readSource(key: corruptedBackupKey) {
            guard let data = sourceVal as? Data else {
                logger.error("InputMate migration failed: corruptedBackup is not Data.")
                migrationFailed = true
                return false
            }
            candidateCorruptedBackup = data
        }

        // 4. PersonalDictionaryStore 사전 이전 검증 (전체 [String: String] 검증, String이 아닌 값 조용히 버리지 않음)
        if let sourceVal = readSource(key: personalDictionaryKey) {
            var parsedDict: [String: String]?
            if let rawDict = sourceVal as? [String: Any] {
                var stringDict: [String: String] = [:]
                var hasNonString = false
                for (k, v) in rawDict {
                    if let str = v as? String {
                        stringDict[k] = str
                    } else {
                        hasNonString = true
                        break
                    }
                }
                if !hasNonString {
                    parsedDict = stringDict
                }
            } else if let data = sourceVal as? Data,
                      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                var stringDict: [String: String] = [:]
                var hasNonString = false
                for (k, v) in plist {
                    if let str = v as? String {
                        stringDict[k] = str
                    } else {
                        hasNonString = true
                        break
                    }
                }
                if !hasNonString {
                    parsedDict = stringDict
                }
            }

            guard let validDict = parsedDict else {
                logger.error("InputMate migration failed: personalDictionary contains non-string values or invalid format.")
                migrationFailed = true
                return false
            }
            candidateDictionary = validDict
        }

        // 5. PersonalDictionaryStore seed 마커 이전 검증 (실제 bool 타입 검증)
        if let sourceVal = readSource(key: personalDictionarySeedKey) {
            let cfType = CFGetTypeID(sourceVal as CFTypeRef)
            let isActualBool = (cfType == CFBooleanGetTypeID())
            guard isActualBool, let seedBool = sourceVal as? Bool else {
                logger.error("InputMate migration failed: personalDictionarySeed is not a valid boolean.")
                migrationFailed = true
                return false
            }
            candidateSeed = seedBool
        }

        // 모든 후보 검증 완료 후 한 번에 복사 (기존 대상 값 우선)
        var migratedCount = 0

        if let prefData = candidatePreferences, target.object(forKey: preferencesKey) == nil {
            target.set(prefData, forKey: preferencesKey)
            migratedCount += 1
        }
        if let rulesData = candidateAppLanguageRules, target.object(forKey: appLanguageRulesKey) == nil {
            target.set(rulesData, forKey: appLanguageRulesKey)
            migratedCount += 1
        }
        if let backupData = candidateCorruptedBackup, target.object(forKey: corruptedBackupKey) == nil {
            target.set(backupData, forKey: corruptedBackupKey)
            migratedCount += 1
        }
        if let dict = candidateDictionary, target.object(forKey: personalDictionaryKey) == nil {
            target.set(dict, forKey: personalDictionaryKey)
            migratedCount += 1
        }
        if let seed = candidateSeed, target.object(forKey: personalDictionarySeedKey) == nil {
            target.set(seed, forKey: personalDictionarySeedKey)
            migratedCount += 1
        }

        target.set(true, forKey: migrationCompletedKey)
        migrationFailed = false
        logger.info("InputMate migration completed successfully (\(migratedCount, privacy: .public) items written).")
        return true
    }
}
