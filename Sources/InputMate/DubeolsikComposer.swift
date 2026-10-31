import Foundation

// 표준 두벌식 자판 위치를 기준으로 QWERTY 소문자 열을 완성형 한글로 조합한다.
// 완성된 음절로만 끝나지 않는 열(자모가 남거나 조합 불가한 경우)은 nil을 돌려준다.
enum DubeolsikComposer {
    private static let keyToJamo: [Character: Character] = [
        "q": "ㅂ", "w": "ㅈ", "e": "ㄷ", "r": "ㄱ", "t": "ㅅ",
        "Q": "ㅃ", "W": "ㅉ", "E": "ㄸ", "R": "ㄲ", "T": "ㅆ",
        "y": "ㅛ", "u": "ㅕ", "i": "ㅑ", "o": "ㅐ", "p": "ㅔ",
        "O": "ㅒ", "P": "ㅖ",
        "a": "ㅁ", "s": "ㄴ", "d": "ㅇ", "f": "ㄹ", "g": "ㅎ",
        "h": "ㅗ", "j": "ㅓ", "k": "ㅏ", "l": "ㅣ",
        "z": "ㅋ", "x": "ㅌ", "c": "ㅊ", "v": "ㅍ",
        "b": "ㅠ", "n": "ㅜ", "m": "ㅡ"
    ]

    static let doubledShiftKeys: Set<Character> = ["Q", "W", "E", "R", "T", "O", "P"]

    private static let initials = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
    private static let medials = Array("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ")
    private static let finals = Array("ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ")
    private static let vowels: Set<Character> = Set("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅛㅜㅠㅡㅣ")

    private static let compoundMedials: [Character: [Character: Character]] = [
        "ㅗ": ["ㅏ": "ㅘ", "ㅐ": "ㅙ", "ㅣ": "ㅚ"],
        "ㅜ": ["ㅓ": "ㅝ", "ㅔ": "ㅞ", "ㅣ": "ㅟ"],
        "ㅡ": ["ㅣ": "ㅢ"]
    ]

    private static let compoundFinals: [Character: [Character: Character]] = [
        "ㄱ": ["ㅅ": "ㄳ"],
        "ㄴ": ["ㅈ": "ㄵ", "ㅎ": "ㄶ"],
        "ㄹ": ["ㄱ": "ㄺ", "ㅁ": "ㄻ", "ㅂ": "ㄼ", "ㅅ": "ㄽ", "ㅌ": "ㄾ", "ㅍ": "ㄿ", "ㅎ": "ㅀ"],
        "ㅂ": ["ㅅ": "ㅄ"]
    ]

    static func compose(fromQwerty word: String) -> String? {
        var output = ""
        var lead: Character?
        var medial: Character?
        var tail: [Character] = []

        func commit() -> Bool {
            guard let lead, let medial,
                  let leadIndex = initials.firstIndex(of: lead),
                  let medialIndex = medials.firstIndex(of: medial) else { return false }
            var finalIndex = 0
            if !tail.isEmpty {
                let tailJamo: Character
                if tail.count == 2 {
                    guard let compound = compoundFinals[tail[0]]?[tail[1]] else { return false }
                    tailJamo = compound
                } else {
                    tailJamo = tail[0]
                }
                guard let index = finals.firstIndex(of: tailJamo) else { return false }
                finalIndex = index + 1
            }
            let scalarValue = 0xAC00 + (leadIndex * 21 + medialIndex) * 28 + finalIndex
            guard let scalar = Unicode.Scalar(scalarValue) else { return false }
            output.append(Character(scalar))
            return true
        }

        func commitAndClear() -> Bool {
            guard commit() else { return false }
            lead = nil
            medial = nil
            tail = []
            return true
        }

        for key in word {
            let normalizedKey = Character(String(key).lowercased())
            guard let jamo = keyToJamo[key] ?? keyToJamo[normalizedKey] else { return nil }
            if vowels.contains(jamo) {
                if medial == nil {
                    // 초성 없는 모음은 완성 음절이 될 수 없다.
                    guard lead != nil else { return nil }
                    medial = jamo
                } else if tail.isEmpty {
                    guard let combined = compoundMedials[medial!]?[jamo] else { return nil }
                    medial = combined
                } else {
                    // 종성 하나를 다음 음절의 초성으로 넘긴다.
                    let stolen = tail.removeLast()
                    guard commitAndClear() else { return nil }
                    lead = stolen
                    medial = jamo
                }
            } else {
                if medial == nil {
                    guard lead == nil else { return nil }
                    lead = jamo
                } else if tail.isEmpty {
                    if finals.contains(jamo) {
                        tail = [jamo]
                    } else {
                        // ㄸ·ㅃ·ㅉ은 받침이 될 수 없으므로 다음 음절의 초성으로 넘긴다.
                        guard initials.contains(jamo), commitAndClear() else { return nil }
                        lead = jamo
                    }
                } else if tail.count == 1, compoundFinals[tail[0]]?[jamo] != nil {
                    tail.append(jamo)
                } else {
                    guard commitAndClear() else { return nil }
                    lead = jamo
                }
            }
        }

        if lead != nil || medial != nil || !tail.isEmpty {
            guard medial != nil, commitAndClear() else { return nil }
        }
        return output.isEmpty ? nil : output
    }

    // 입력 도중의 화면 표시. 낱자모가 남아도 실패하지 않고 그대로 보여 준다.
    struct Rendering {
        let text: String
        // 초성 없는 모음이나 조합되지 못하고 밀려난 자음이 있으면 true. 끝의 초성 하나는 입력 중이므로 제외한다.
        let hasLooseJamo: Bool
        let endsWithLoneInitial: Bool
        let syllableCount: Int

        var isComplete: Bool { !hasLooseJamo && !endsWithLoneInitial && syllableCount > 0 }
    }

    static func isVowelKey(_ key: Character) -> Bool {
        guard let jamo = keyToJamo[key] ?? keyToJamo[Character(String(key).lowercased())] else { return false }
        return vowels.contains(jamo)
    }

    // 한글 입력기처럼 키를 하나씩 조합한다. 받침 넘김·겹모음·겹받침을 모두 반영하며, 두벌식 키가 아니면 nil.
    static func render<Keys: Collection>(keys: Keys) -> Rendering? where Keys.Element == Character {
        var output = ""
        var lead: Character?
        var medial: Character?
        var tail: [Character] = []
        var hasLooseJamo = false
        var syllableCount = 0

        func flush() {
            if let lead, let medial, let syllable = syllable(lead: lead, medial: medial, tail: tail) {
                output.append(syllable)
                syllableCount += 1
            } else {
                if let lead { output.append(lead) }
                if let medial { output.append(medial) }
                output.append(contentsOf: tail)
                if lead != nil || medial != nil { hasLooseJamo = true }
            }
            lead = nil
            medial = nil
            tail = []
        }

        for key in keys {
            guard let jamo = keyToJamo[key] ?? keyToJamo[Character(String(key).lowercased())] else { return nil }
            if vowels.contains(jamo) {
                if let current = medial {
                    if tail.isEmpty {
                        if let combined = compoundMedials[current]?[jamo] {
                            medial = combined
                        } else {
                            flush()
                            medial = jamo
                        }
                    } else {
                        let stolen = tail.removeLast()
                        flush()
                        lead = stolen
                        medial = jamo
                    }
                } else {
                    medial = jamo
                }
            } else if medial == nil {
                if lead != nil { flush() }
                lead = jamo
            } else if lead == nil {
                // 초성 없는 모음 뒤의 자음은 받침이 될 수 없다.
                flush()
                lead = jamo
            } else if tail.isEmpty, finals.contains(jamo) {
                tail = [jamo]
            } else if tail.count == 1, compoundFinals[tail[0]]?[jamo] != nil {
                tail.append(jamo)
            } else {
                flush()
                lead = jamo
            }
        }

        var endsWithLoneInitial = false
        if let lead, medial == nil {
            output.append(lead)
            endsWithLoneInitial = true
        } else if lead != nil || medial != nil {
            flush()
        }
        return Rendering(
            text: output, hasLooseJamo: hasLooseJamo,
            endsWithLoneInitial: endsWithLoneInitial, syllableCount: syllableCount
        )
    }

    private static func syllable(lead: Character, medial: Character, tail: [Character]) -> Character? {
        guard let leadIndex = initials.firstIndex(of: lead),
              let medialIndex = medials.firstIndex(of: medial) else { return nil }
        var finalIndex = 0
        if !tail.isEmpty {
            let tailJamo = tail.count == 2 ? compoundFinals[tail[0]]?[tail[1]] : tail[0]
            guard let tailJamo, let index = finals.firstIndex(of: tailJamo) else { return nil }
            finalIndex = index + 1
        }
        return Unicode.Scalar(0xAC00 + (leadIndex * 21 + medialIndex) * 28 + finalIndex).map(Character.init)
    }

    private static let jamoToKey: [Character: Character] =
        Dictionary(keyToJamo.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })

    // 복합 모음·받침을 두벌식에서 실제로 누르는 낱자 순서로 되돌리기 위한 표.
    private static let decomposition: [Character: [Character]] = {
        var table: [Character: [Character]] = [:]
        for (first, rest) in compoundMedials { for (second, joined) in rest { table[joined] = [first, second] } }
        for (first, rest) in compoundFinals { for (second, joined) in rest { table[joined] = [first, second] } }
        return table
    }()

    // 화면의 한글(완성형·낱자모)을 두벌식 키 열로 역변환한다. 한글 자모가 아닌 글자가 있으면 nil이다.
    static func qwerty(fromHangul text: String) -> String? {
        var keys = ""
        func append(_ jamo: Character) -> Bool {
            for single in decomposition[jamo] ?? [jamo] {
                guard let key = jamoToKey[single] else { return false }
                keys.append(key)
            }
            return true
        }
        for character in text {
            guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return nil }
            let value = Int(scalar.value)
            if (0xAC00...0xD7A3).contains(value) {
                let offset = value - 0xAC00
                guard append(initials[offset / 588]), append(medials[(offset % 588) / 28]) else { return nil }
                if offset % 28 != 0, !append(finals[offset % 28 - 1]) { return nil }
            } else {
                guard append(character) else { return nil }
            }
        }
        return keys.isEmpty ? nil : keys
    }
}
