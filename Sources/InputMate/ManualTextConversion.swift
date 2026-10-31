import Foundation
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

// 수동 강제 변환('') 신호 처리 도우미.
// 두벌식 오타 복원, 월 이름(1월..12월), 확정 어휘/외래어, 인명 보수적 로마자 표기 및 온디바이스 번역을 통합 처리한다.
enum ManualTextConversion {
    enum Result: Equatable {
        case synchronous(String)
        case needsAsyncTranslation(String)
    }

    // 1월..12월 -> 영어 월 이름
    private static let monthNames: [String: String] = [
        "1월": "January",
        "2월": "February",
        "3월": "March",
        "4월": "April",
        "5월": "May",
        "6월": "June",
        "7월": "July",
        "8월": "August",
        "9월": "September",
        "10월": "October",
        "11월": "November",
        "12월": "December"
    ]

    // 확정 사전: 공통 외래어 및 일상 한글 어휘.
    // 온디바이스 번역 모델이 없거나 구형 OS에서도 즉시 정확히 변환되도록 한다.
    private static let commonWordDictionary: [String: String] = [
        // 요구사항 명시 단어
        "서비스": "service",
        "컴퓨터": "computer",
        "사과": "apple",
        "회의": "meeting",
        "강아지": "puppy", // 성씨(강) 오분류 방지용 명시 포함

        // 일상 및 IT 외래어
        "커피": "coffee",
        "카페": "cafe",
        "메뉴": "menu",
        "버스": "bus",
        "택시": "taxi",
        "지하철": "subway",
        "기차": "train",
        "비행기": "airplane",
        "호텔": "hotel",
        "레스토랑": "restaurant",
        "마트": "mart",
        "마켓": "market",
        "쇼핑": "shopping",
        "인터넷": "internet",
        "시스템": "system",
        "프로그램": "program",
        "프로젝트": "project",
        "테스트": "test",
        "데이터": "data",
        "서버": "server",
        "네트워크": "network",
        "디자인": "design",
        "스마트폰": "smartphone",
        "노트북": "laptop",
        "모니터": "monitor",
        "키보드": "keyboard",
        "마우스": "mouse",
        "팀": "team",
        "매니저": "manager",
        "카메라": "camera",
        "비디오": "video",
        "오디오": "audio",
        "뉴스": "news",
        "이메일": "email",
        "메시지": "message",
        "아이디어": "idea",

        // 빈출 한국어 기본 단어
        "사람": "person",
        "친구": "friend",
        "가족": "family",
        "선생님": "teacher",
        "학생": "student",
        "학교": "school",
        "회사": "company",
        "사무실": "office",
        "업무": "work",
        "오늘": "today",
        "내일": "tomorrow",
        "어제": "yesterday",
        "지금": "now",
        "시간": "time",
        "날씨": "weather",
        "봄": "spring",
        "여름": "summer",
        "가을": "autumn",
        "겨울": "winter",
        "월요일": "Monday",
        "화요일": "Tuesday",
        "수요일": "Wednesday",
        "목요일": "Thursday",
        "금요일": "Friday",
        "토요일": "Saturday",
        "일요일": "Sunday",
        "사랑": "love",
        "감사": "thanks",
        "안녕": "hello",
        "음악": "music",
        "영화": "movie",
        "사진": "photo",
        "책": "book",
        "편지": "letter",
        "전화": "phone",
        "물": "water",
        "밥": "meal",
        "음식": "food",
        "식당": "restaurant",
        "병원": "hospital",
        "약국": "pharmacy",
        "집": "house",
        "방": "room",
        "문": "door",
        "창문": "window",
        "자동차": "car",
        "자전거": "bicycle",
        "길": "road",
        "도시": "city",
        "나라": "country",
        "고양이": "cat"
    ]

    // 한국 주요 성씨 (단성 80여 개)
    private static let singleSurnames: Set<String> = [
        "김", "이", "박", "최", "정", "강", "조", "윤", "장", "임",
        "한", "오", "서", "신", "권", "황", "안", "송", "류", "홍",
        "고", "문", "양", "손", "배", "백", "허", "유", "남", "심",
        "노", "하", "곽", "성", "차", "주", "우", "구", "라", "민",
        "진", "지", "엄", "채", "원", "천", "방", "공", "현", "함",
        "변", "염", "여", "추", "도", "소", "석", "선", "설", "마",
        "길", "연", "위", "표", "명", "기", "반", "왕", "금", "옥",
        "육", "인", "맹", "제", "탁", "국", "어", "은", "편", "용"
    ]

    // 복성 (2글자)
    private static let compoundSurnames: Set<String> = [
        "남궁", "황보", "제갈", "사공", "선우", "독고"
    ]

    // 성씨 글자로 시작하지만 일반 명사/단어인 어휘 배제 목록
    private static let commonWordPrefixExclusions: Set<String> = [
        "강아지", "고양이", "박물관", "임금님", "이유식", "정치인", "사과나무",
        "배추김치", "한국어", "한글날", "대한민국", "우리나라", "신문사", "안전제일"
    ]

    /// 바로 앞 단어를 분석해 동기 치환값 또는 비동기 번역 필요 여부를 판정한다.
    static func convertPrecedingWord(_ word: String) -> Result? {
        guard !word.isEmpty else { return nil }

        // 1. ASCII 영문 자판 입력인 경우: 두벌식 오타 한글 복원 (tjqltm -> 서비스)
        if word.allSatisfy({ ("a"..."z").contains($0) || ("A"..."Z").contains($0) }) {
            if let hangul = DubeolsikComposer.compose(fromQwerty: word), hangul != word {
                return .synchronous(hangul)
            }
            return nil
        }

        // 2. 숫자+월 표기 (1월..12월, 5월 -> May)
        if let monthEnglish = monthName(for: word) {
            return .synchronous(monthEnglish)
        }

        // 3. 확정 어휘 사전 (사과 -> apple, 회의 -> meeting, 서비스 -> service, 컴퓨터 -> computer 등)
        if let translated = commonWordDictionary[word] {
            return .synchronous(translated)
        }

        // 4. 인명 보수적 판별: 성씨+이름 구조이며 일반 어휘가 아닐 때 발음 기반 로마자 표기
        if let romanizedName = conservativeRomanizedName(for: word) {
            return .synchronous(romanizedName)
        }

        // 5. 그 외 완전한 한글 어휘: 시스템 온디바이스 번역 요청
        if isAllHangulSyllables(word) {
            #if canImport(Translation)
            if #available(macOS 26.0, *) {
                return .needsAsyncTranslation(word)
            }
            #endif
        }

        return nil
    }

    // MARK: - 현재 줄 문장 번역(역슬래시 두 개)

    /// 한 번에 읽는 현재 줄 앞부분의 상한(UTF-16 단위). 이보다 긴 줄은 잘린 꼬리만 변환하지 않고 그대로 둔다.
    static let maxLinePrefixUTF16 = 2048

    enum LineDirection: Equatable {
        case koreanToEnglish
        case englishToKorean
    }

    struct LineRequest: Equatable {
        /// 번역 모델에 넘기는 공백 제거본. 선택 범위·되돌리기·캐시 키에는 쓰지 않는다.
        let compact: String
        let direction: LineDirection
    }

    enum LinePrefix: Equatable {
        case prefix(String)
        case tooLong
    }

    private static let lineBreakUnits: Set<UInt16> = [0x0A, 0x0D, 0x2028, 0x2029]

    /// 커서(트리거 앞) 직전에서 읽은 창에서 현재 논리 줄의 앞부분을 잘라낸다. \n·\r(CRLF 포함)을 줄 경계로 보며
    /// 앞뒤 공백은 그대로 유지한다. 창이 문서 처음까지 닿지 않았는데 줄 경계가 없으면 .tooLong.
    static func currentLinePrefix(fromWindow text: String, windowReachesStart: Bool) -> LinePrefix {
        let units = Array(text.utf16)
        if let breakIndex = units.lastIndex(where: { lineBreakUnits.contains($0) }) {
            let tail = Array(units[(breakIndex + 1)...])
            return .prefix(String(utf16CodeUnits: tail, count: tail.count))
        }
        guard windowReachesStart, units.count <= maxLinePrefixUTF16 else { return .tooLong }
        return .prefix(text)
    }

    private static func isHangulScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7A3).contains(scalar.value) || (0x1100...0x11FF).contains(scalar.value)
            || (0x3130...0x318F).contains(scalar.value)
    }

    /// 줄의 모든 공백을 제거해 번역 요청을 만든다. 한글이 있으면 한→영, 한글 없이 ASCII 영문자만 있으면 영→한.
    /// 글자가 없거나 다른 문자 체계가 섞여 방향이 불분명하면 nil(원문 유지).
    static func lineTranslationRequest(for line: String) -> LineRequest? {
        let compact = String(String.UnicodeScalarView(line.unicodeScalars.filter {
            !$0.properties.isWhitespace && !lineBreakUnits.contains(UInt16(truncatingIfNeeded: $0.value))
        }))
        var hasHangul = false
        var hasASCIILetter = false
        var hasOtherLetter = false
        for scalar in compact.unicodeScalars where scalar.properties.isAlphabetic {
            if isHangulScalar(scalar) {
                hasHangul = true
            } else if scalar.isASCII {
                hasASCIILetter = true
            } else {
                hasOtherLetter = true
            }
        }
        if hasHangul { return LineRequest(compact: compact, direction: .koreanToEnglish) }
        if hasASCIILetter && !hasOtherLetter { return LineRequest(compact: compact, direction: .englishToKorean) }
        return nil
    }

    /// 번역 결과의 바깥 공백만 다듬고 내부 공백은 유지한다. 비었거나 원문과 같거나 여러 줄이거나
    /// 목표 언어로 바뀌지 않은 결과는 nil.
    static func acceptedLineTranslation(_ translated: String, for request: LineRequest, originalLine: String) -> String? {
        let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains("\r"),
              trimmed != request.compact,
              trimmed != originalLine.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let hasHangul = trimmed.unicodeScalars.contains(where: isHangulScalar)
        switch request.direction {
        case .koreanToEnglish: return hasHangul ? nil : trimmed
        case .englishToKorean: return hasHangul ? trimmed : nil
        }
    }

    // "5월", "05월" 같은 숫자 월 토큰만 인정한다(1~12).
    private static func monthName(for word: String) -> String? {
        guard word.hasSuffix("월") else { return nil }
        let digits = word.dropLast()
        guard (1...2).contains(digits.count), digits.allSatisfy({ ("0"..."9").contains($0) }),
              let month = Int(digits), (1...12).contains(month) else { return nil }
        return monthNames["\(month)월"]
    }

    // 이름 첫 음절·둘째 음절로 쓰이는 흔한 음절. 일반 명사에서는 드문 조합만 이름으로 본다.
    private static let givenFirstSyllables: Set<Character> = [
        "민", "준", "서", "지", "현", "영", "승", "병", "철", "재", "성", "도", "수", "예",
        "하", "동", "태", "경", "은", "진", "우", "건", "혜", "윤", "상"
    ]
    private static let givenSecondSyllables: Set<Character> = [
        "준", "연", "우", "윤", "은", "훈", "호", "진", "수", "현", "희", "영", "빈", "기",
        "민", "석", "혁", "규", "환", "욱", "찬", "균", "용", "숙", "순", "율"
    ]

    /// 보수적 인명 판별 및 로마자 표기.
    /// 성씨 하나(또는 복성) + 흔한 이름 음절 두 개로 정확히 이루어진 경우만 이름으로 본다.
    /// 성씨로 시작한다는 이유만으로 이름으로 보지 않으며, 그 밖의 단어는 번역 경로로 넘어간다.
    static func conservativeRomanizedName(for text: String) -> String? {
        guard isAllHangulSyllables(text) else { return nil }
        guard !commonWordDictionary.keys.contains(text), !commonWordPrefixExclusions.contains(text) else { return nil }

        let chars = Array(text)
        let count = chars.count

        var surnameLength = 0
        if count == 4 && compoundSurnames.contains(String(chars[0...1])) {
            surnameLength = 2
        } else if count == 3 && singleSurnames.contains(String(chars[0])) {
            surnameLength = 1
        }

        guard surnameLength > 0,
              givenFirstSyllables.contains(chars[surnameLength]),
              givenSecondSyllables.contains(chars[surnameLength + 1]) else { return nil }
        let surname = String(chars[..<surnameLength])
        let given = String(chars[surnameLength...])

        // 성씨와 이름 음절 로마자 변환
        let surnameLatin = romanizeSyllable(surname).capitalized
        let givenLatin = romanizeGivenName(given)

        guard !surnameLatin.isEmpty, !givenLatin.isEmpty else { return nil }
        return "\(surnameLatin) \(givenLatin)"
    }

    /// 일반 단어 또는 번역 결과가 한글 그대로일 때의 발음 기반 로마자 표기 fallback
    static func romanizeGeneral(_ text: String) -> String {
        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return (mutable as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isAllHangulSyllables(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        for scalar in text.unicodeScalars {
            // 한글 완성형 음절 (가..힣: 0xAC00...0xD7A3)
            guard scalar.value >= 0xAC00 && scalar.value <= 0xD7A3 else { return false }
        }
        return true
    }

    private static func romanizeSyllable(_ syllable: String) -> String {
        romanizeGeneral(syllable)
    }

    private static func romanizeGivenName(_ given: String) -> String {
        // 이름의 각 음절을 공백 없이 붙이고 첫 글자만 대문자화한다 (예: 병기 -> Byeonggi). 선호 표기는 개인 사전으로 덮어쓴다
        var combined = ""
        for char in given {
            combined += romanizeGeneral(String(char))
        }
        guard !combined.isEmpty else { return "" }
        return combined.prefix(1).uppercased() + combined.dropFirst().lowercased()
    }
}

#if canImport(Translation)
// macOS 26+ TranslationSession 온디바이스 배경 번역 엔진
@available(macOS 26.0, *)
enum TranslationEngine {
    static func translate(text: String, source: String = "ko", target: String = "en") async throws -> String {
        let session = TranslationSession(
            installedSource: Locale.Language(identifier: source),
            target: Locale.Language(identifier: target)
        )
        let response = try await session.translate(text)
        return response.targetText
    }

    /// 설치된 모델이 있을 때만 true. 다운로드를 시작하지 않는다.
    static func isInstalled(source: String, target: String) async -> Bool {
        await LanguageAvailability().status(
            from: Locale.Language(identifier: source), to: Locale.Language(identifier: target)
        ) == .installed
    }
}
#endif
