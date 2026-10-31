import Foundation

// 입력 중인 한 단어의 키 열을 한글·영어 구간으로 나누는 기기 내부 판단 규칙.
// 두벌식 조합 가능성과 영어 단어·글자쌍 자료만 쓰며, 한쪽으로 정해진 구간은 강한 반대 신호가 있을 때만 바꾼다.
@MainActor
enum LanguageIntent {
    struct Segment: Equatable {
        var start: Int
        var korean: Bool
    }

    static func display(of keys: [Character], segments: [Segment]) -> String {
        var text = ""
        for (index, segment) in segments.enumerated() {
            let end = index + 1 < segments.count ? segments[index + 1].start : keys.count
            guard segment.start < end else { continue }
            let slice = keys[segment.start..<end]
            if segment.korean, let rendering = DubeolsikComposer.render(keys: slice) {
                text += rendering.text
            } else {
                text += String(slice)
            }
        }
        return text
    }

    // 마지막 구간에서 시작하는 한글 구간의 위치. 앞부분은 영어 줄기(약어·흔한 단어·영어다운 철자)여야 한다.
    static func koreanStart(
        in keys: [Character], from start: Int, lenient: Bool, allowMixed: Bool, atEnd: Bool
    ) -> Int? {
        let whole = keys[start...]
        guard whole.count >= 2, !isEnglishLike(whole) else { return nil }
        for split in start...(keys.count - 2) {
            let tail = keys[split...]
            guard tail.allSatisfy({ $0.isLowercase || DubeolsikComposer.doubledShiftKeys.contains($0) }),
                  let rendering = DubeolsikComposer.render(keys: tail),
                  !rendering.hasLooseJamo, rendering.syllableCount >= 1,
                  !atEnd || !rendering.endsWithLoneInitial else { continue }
            let signal = koreanSignal(tail)
            if split == start {
                if signal >= 2 || (signal >= 1 && (tail.count >= 3 || atEnd)) || (lenient && tail.count >= 2) {
                    return split
                }
            } else if allowMixed, isEnglishStem(keys[start..<split]) {
                let junction = bigram(keys[split - 1], keys[split])
                if signal + (KoreanTypoCorrector.commonEnglishBigrams.contains(junction) ? 0 : 1) >= 1 {
                    return split
                }
            }
        }
        return nil
    }

    // 한글 구간이 조합 불가능해졌을 때 영어로 돌릴 위치. 앞부분은 완성된 음절로 끝나야 그대로 남긴다.
    static func englishStart(in keys: [Character], from start: Int, atEnd: Bool) -> Int? {
        let segment = keys[start...]
        guard segment.count >= 2, let rendering = DubeolsikComposer.render(keys: segment) else { return nil }
        let shiftedLetters = segment.filter {
            $0.isUppercase && !DubeolsikComposer.doubledShiftKeys.contains($0)
        }.count
        guard rendering.hasLooseJamo || (atEnd && rendering.endsWithLoneInitial) || shiftedLetters >= 2 else {
            return nil
        }
        for split in start...(keys.count - 2) {
            let suffix = keys[split...]
            guard isEnglishLike(suffix) else { continue }
            if split == start { return split }
            guard suffix.count >= 3,
                  let prefix = DubeolsikComposer.render(keys: keys[start..<split]), prefix.isComplete else { continue }
            return split
        }
        return nil
    }

    // 흔한 영어 단어나 그 앞부분, 모든 글자쌍이 흔한 영어다운 철자, 대문자 약어.
    static func isEnglishLike(_ word: ArraySlice<Character>) -> Bool {
        guard word.count >= 2 else { return false }
        // 단어 중간의 Shift 쌍자음·ㅒ·ㅖ 키(했·뺐 등)는 영어 철자로 보지 않는다. 대문자 약어는 예외.
        if !isAcronym(word),
           word.dropFirst().contains(where: { DubeolsikComposer.doubledShiftKeys.contains($0) }) {
            return false
        }
        let text = String(word)
        let lowered = text.lowercased()
        return KoreanTypoCorrector.commonEnglishWords.contains(lowered)
            || commonEnglishPrefixes.contains(lowered)
            || isAcronym(word)
            || (word.count >= 3 && KoreanTypoCorrector.looksLikeEnglish(text))
    }

    private static func isEnglishStem(_ stem: ArraySlice<Character>) -> Bool {
        isAcronym(stem)
            || (stem.count >= 3 && KoreanTypoCorrector.commonEnglishWords.contains(String(stem).lowercased()))
            || (stem.count >= 3 && KoreanTypoCorrector.looksLikeEnglish(String(stem)))
    }

    private static func isAcronym(_ word: ArraySlice<Character>) -> Bool {
        word.count >= 2 && word.allSatisfy { $0.isUppercase }
    }

    // 영어에서 드문 글자쌍과 Shift 쌍자음·ㅒ·ㅖ 입력 수. 클수록 한글 의도일 가능성이 높다.
    private static func koreanSignal(_ keys: ArraySlice<Character>) -> Int {
        var signal = keys.filter { DubeolsikComposer.doubledShiftKeys.contains($0) }.count
        var previous: Character?
        for key in keys {
            if let previous, !KoreanTypoCorrector.commonEnglishBigrams.contains(bigram(previous, key)) {
                signal += 1
            }
            previous = key
        }
        return signal
    }

    private static func bigram(_ first: Character, _ second: Character) -> String {
        (String(first) + String(second)).lowercased()
    }

    private static let commonEnglishPrefixes: Set<String> = {
        var prefixes: Set<String> = []
        for word in KoreanTypoCorrector.commonEnglishWords where word.count > 2 {
            for length in 2..<word.count { prefixes.insert(String(word.prefix(length))) }
        }
        return prefixes
    }()
}
