import Foundation

public struct GuardPreferences: Codable, Equatable, Sendable {
    public var isEnabled = false
    public var trackpadProtectionEnabled = false
    public var blockPointerMovement = true
    public var blockClicks = true
    public var blockScrolling = true
    public var launchAtLogin = false
    public var restartProtectionAfterWake = true
    public var automaticallyRecoverFromHighLoad = true
    public var correctKoreanTypos = false
    public var preferKoreanTypoCorrection = false
    public var correctMixedAndRestoreEnglish = true
    public var continuousLanguageSwitching = true
    public var firstWordRecoveryEnabled = false
    public var firstWordRecoveryBundleIDs: [String] = ["com.openai.codex"]
    public var manualWordConversionEnabled = true
    public var sentenceTranslationEnabled = true
    public var personalDictionaryEnabled = true
    public var personalDictionaryAutoLearnEnabled = true
    public var activationRegion = ActivationRegion.default

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case trackpadProtectionEnabled
        case blockPointerMovement
        case blockClicks
        case blockScrolling
        case launchAtLogin
        case restartProtectionAfterWake
        case automaticallyRecoverFromHighLoad
        case correctKoreanTypos
        case preferKoreanTypoCorrection
        case correctMixedAndRestoreEnglish
        case continuousLanguageSwitching
        case firstWordRecoveryEnabled
        case firstWordRecoveryBundleIDs
        case manualWordConversionEnabled
        case sentenceTranslationEnabled
        case personalDictionaryEnabled
        case personalDictionaryAutoLearnEnabled
        case activationRegion
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        trackpadProtectionEnabled = try values.decodeIfPresent(Bool.self, forKey: .trackpadProtectionEnabled) ?? isEnabled
        blockPointerMovement = try values.decodeIfPresent(Bool.self, forKey: .blockPointerMovement) ?? true
        blockClicks = try values.decodeIfPresent(Bool.self, forKey: .blockClicks) ?? true
        blockScrolling = try values.decodeIfPresent(Bool.self, forKey: .blockScrolling) ?? true
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        restartProtectionAfterWake = try values.decodeIfPresent(Bool.self, forKey: .restartProtectionAfterWake) ?? true
        automaticallyRecoverFromHighLoad = try values.decodeIfPresent(Bool.self, forKey: .automaticallyRecoverFromHighLoad) ?? true
        correctKoreanTypos = try values.decodeIfPresent(Bool.self, forKey: .correctKoreanTypos) ?? false
        preferKoreanTypoCorrection = try values.decodeIfPresent(Bool.self, forKey: .preferKoreanTypoCorrection) ?? false
        correctMixedAndRestoreEnglish = try values.decodeIfPresent(Bool.self, forKey: .correctMixedAndRestoreEnglish) ?? true
        continuousLanguageSwitching = try values.decodeIfPresent(Bool.self, forKey: .continuousLanguageSwitching) ?? true
        firstWordRecoveryEnabled = try values.decodeIfPresent(Bool.self, forKey: .firstWordRecoveryEnabled) ?? false
        firstWordRecoveryBundleIDs = try values.decodeIfPresent([String].self, forKey: .firstWordRecoveryBundleIDs) ?? ["com.openai.codex"]
        manualWordConversionEnabled = try values.decodeIfPresent(Bool.self, forKey: .manualWordConversionEnabled) ?? correctKoreanTypos
        sentenceTranslationEnabled = try values.decodeIfPresent(Bool.self, forKey: .sentenceTranslationEnabled) ?? correctKoreanTypos
        personalDictionaryEnabled = try values.decodeIfPresent(Bool.self, forKey: .personalDictionaryEnabled) ?? true
        personalDictionaryAutoLearnEnabled = try values.decodeIfPresent(Bool.self, forKey: .personalDictionaryAutoLearnEnabled) ?? true
        activationRegion = try values.decodeIfPresent(ActivationRegion.self, forKey: .activationRegion) ?? .default
    }
}
