import CoreGraphics
import Foundation

// 원화 환산 파서(Foundation만 사용 — Safari 확장·메인 앱이 함께 컴파일). BrowserExtension/shared/fx.js와 같은 규칙이다.
// - 외국 금액(통화 기호·ISO 4217 코드·통화 이름 + 숫자)만 찾는다. 날짜·버전·금액 아닌 숫자와 원화(KRW)는 건드리지 않는다.
// - 모호한 표기($·¥·元·peso·rupee 등)는 명시 코드나 언어/나라 단서가 있을 때만 정하고, 없으면 건너뛴다.
// - 환산은 금액 × KRW ÷ 해당 통화(USD=1 기준 환율의 교차 비율). 고정·내장 환율은 없다.

/// 언어/나라 단서. 모두 선택값이며 없으면 단서 없음이다.
struct CurrencyContext {
    var lang = ""
    var script = ""
    var country = ""
    var kana = false
    var decimalComma = false

    private static let decimalCommaLangs: Set<String> = ["de", "fr", "es", "it", "pt", "nl", "ru", "id", "vi", "tr", "pl", "cs", "sk",
        "sv", "da", "nb", "no", "fi", "hu", "ro", "bg", "uk", "hr", "sl", "el", "ca", "ms"]
    private static let decimalCommaCountries: Set<String> = ["DE", "FR", "ES", "IT", "PT", "BR", "NL", "RU", "ID", "VN", "TR", "PL",
        "CZ", "SK", "SE", "DK", "NO", "FI", "HU", "RO", "BG", "UA", "HR", "SI", "GR", "AR", "CL", "CO", "UY", "AT", "BE"]
    private static let nonCountryTLDs: Set<String> = ["io", "ai", "tv", "me", "co", "fm", "ly", "to", "ws", "cc", "gg", "gl", "sh", "ac", "am", "ms", "so", "ee"]

    init() {}

    /// htmlLang: 문서 언어 태그, textLang: 이 글자의 판별 언어(있으면 우선), host: 문서 호스트, text: 원문(가나 단서용).
    init(htmlLang: String? = nil, textLang: String? = nil, host: String? = nil, text: String? = nil) {
        let tag = (textLang?.isEmpty == false ? textLang! : (htmlLang ?? "")).replacingOccurrences(of: "_", with: "-")
        let parts = tag.split(separator: "-").map(String.init)
        lang = (parts.first ?? "").lowercased()
        var region = ""
        for part in parts.dropFirst() {
            if part.count == 4, part.allSatisfy(\.isLetter) { script = part.lowercased() }
            else if part.count == 2, part.allSatisfy(\.isLetter) { region = part.uppercased() }
        }
        if lang == "zh", script.isEmpty { script = ["TW", "HK", "MO"].contains(region) ? "hant" : "hans" }
        if region.isEmpty, let html = htmlLang {
            let pieces = html.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            if let two = pieces.dropFirst().first(where: { $0.count == 2 && $0.allSatisfy(\.isLetter) }) { region = two.uppercased() }
        }
        country = region
        if country.isEmpty, let host {
            let tld = host.lowercased().split(separator: ".").last.map(String.init) ?? ""
            if tld.count == 2, tld.allSatisfy(\.isLetter), !Self.nonCountryTLDs.contains(tld) { country = tld == "uk" ? "GB" : tld.uppercased() }
        }
        kana = (text ?? "").unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
        decimalComma = Self.decimalCommaLangs.contains(lang) || (lang.isEmpty && Self.decimalCommaCountries.contains(country))
    }
}

struct CurrencyMention: Equatable {
    /// 통화 표기를 포함한 금액 전체의 문자(Character) 범위. 환산 주석은 end 바로 뒤에 붙인다.
    let start: Int
    let end: Int
    let code: String
    let amount: Double
    let krw: Double?
    /// "약 138,600원". 환율이 없거나 너무 작은 금액이면 nil.
    let label: String?
}

enum CurrencyParser {
    static let fiat: Set<String> = Set(("AED AFN ALL AMD ANG AOA ARS AUD AWG AZN BAM BBD BDT BGN BHD BIF BMD BND BOB BRL BSD BTN BWP BYN BZD " +
        "CAD CDF CHF CLP CNY COP CRC CUP CVE CZK DJF DKK DOP DZD EGP ERN ETB EUR FJD FKP GBP GEL GHS GIP GMD GNF GTQ GYD HKD HNL " +
        "HTG HUF IDR ILS INR IQD IRR ISK JMD JOD JPY KES KGS KHR KMF KPW KRW KWD KYD KZT LAK LBP LKR LRD LSL LYD MAD MDL MGA MKD " +
        "MMK MNT MOP MRU MUR MVR MWK MXN MYR MZN NAD NGN NIO NOK NPR NZD OMR PAB PEN PGK PHP PKR PLN PYG QAR RON RSD RUB RWF SAR " +
        "SBD SCR SDG SEK SGD SHP SLE SLL SOS SRD SSP STN SVC SYP SZL THB TJS TMT TND TOP TRY TTD TWD TZS UAH UGX USD UYU UZS VES " +
        "VND VUV WST XAF XCD XCG XOF XPF YER ZAR ZMW ZWG ZWL").split(separator: " ").map(String.init))

    // 영어 낱말·회사명과 겹치는 코드는 금액 앞/뒤 어디든 읽되, 비금액 문맥만 nonMoneyISO가 걸러 낸다.
    private static let wordlikeCodes: Set<String> = ["ALL", "TOP", "TRY", "MAD", "PEN", "SOS", "CUP", "COP", "BAM", "AMD", "LAK", "ANG", "BIF"]
    private static let zeroDecimal: Set<String> = ["JPY", "KRW", "VND", "IDR", "CLP", "PYG", "UGX", "RWF", "XAF", "XOF", "XPF", "KMF", "GNF", "DJF", "BIF", "VUV", "ISK"]
    private static let threeDecimal: Set<String> = ["BHD", "KWD", "OMR", "JOD", "TND", "IQD", "LYD"]
    private static let dotGrouping: Set<String> = ["EUR", "IDR", "VND", "BRL", "TRY", "ARS", "CLP", "COP", "PLN", "CZK", "HUF", "DKK", "RUB", "RON",
        "UAH", "HRK", "BGN", "PYG", "UYU"]
    // '$'를 미국 달러로 보는 언어(문서화된 가정): 영어(미국 외 지역 단서 없을 때)·한국어·일본어·중국어(본토)·독일어·프랑스어·이탈리아어·네덜란드어.
    private static let usdDefaultLangs: Set<String> = ["en", "ko", "ja", "zh", "de", "fr", "it", "nl"]
    private static let countryDollar: [String: String] = ["US": "USD", "CA": "CAD", "AU": "AUD", "NZ": "NZD", "HK": "HKD", "SG": "SGD",
        "TW": "TWD", "MX": "MXN", "AR": "ARS", "CL": "CLP", "CO": "COP", "UY": "UYU", "CU": "CUP", "DO": "DOP", "LR": "LRD", "FJ": "FJD",
        "BS": "BSD", "BB": "BBD", "BZ": "BZD", "BM": "BMD", "BN": "BND", "JM": "JMD", "NA": "NAD", "SB": "SBD", "SR": "SRD", "TT": "TTD", "ZW": "ZWL"]
    private static let countryPeso: [String: String] = ["PH": "PHP", "MX": "MXN", "AR": "ARS", "CL": "CLP", "CO": "COP", "UY": "UYU", "CU": "CUP", "DO": "DOP"]
    private static let countryRupee: [String: String] = ["IN": "INR", "PK": "PKR", "LK": "LKR", "NP": "NPR", "MU": "MUR", "SC": "SCR"]

    private static let ambDollar = "AMB_DOLLAR", ambYen = "AMB_YEN", ambYuan = "AMB_YUAN"
    private static let ambPeso = "AMB_PESO", ambRupee = "AMB_RUPEE", ambFranc = "AMB_FRANC"

    private struct Symbol { let chars: [Character]; let key: String }
    private enum WordKind { case latin, hangul, katakana, other }
    private struct Word { let chars: [Character]; let key: String; let kind: WordKind }

    private static let symbols: [Symbol] = {
        let raw: [(String, String)] = [
            ("US$", "USD"), ("US＄", "USD"), ("CA$", "CAD"), ("CAD$", "CAD"), ("CDN$", "CAD"), ("C$", "CAD"), ("AU$", "AUD"), ("A$", "AUD"),
            ("NZ$", "NZD"), ("HK$", "HKD"), ("HK＄", "HKD"), ("NT$", "TWD"), ("NT＄", "TWD"), ("TW$", "TWD"), ("SG$", "SGD"), ("S$", "SGD"),
            ("R$", "BRL"), ("MX$", "MXN"), ("Mex$", "MXN"), ("Rp.", "IDR"), ("Rp", "IDR"), ("RM", "MYR"), ("Php", "PHP"), ("₱", "PHP"),
            ("€", "EUR"), ("£", "GBP"), ("₹", "INR"), ("฿", "THB"), ("₫", "VND"), ("₽", "RUB"), ("₺", "TRY"), ("₪", "ILS"), ("₴", "UAH"),
            ("₦", "NGN"), ("₭", "LAK"), ("₸", "KZT"), ("₾", "GEL"), ("₼", "AZN"), ("₡", "CRC"), ("₲", "PYG"), ("₵", "GHS"),
            ("zł", "PLN"), ("Kč", "CZK"), ("円", "JPY"), ("圓", "JPY"), ("엔", "JPY"),
            ("人民币", "CNY"), ("人民幣", "CNY"), ("人民元", "CNY"), ("日元", "JPY"), ("日圆", "JPY"), ("日圓", "JPY"),
            ("新台币", "TWD"), ("新台幣", "TWD"), ("新臺幣", "TWD"), ("台币", "TWD"), ("台幣", "TWD"), ("港币", "HKD"), ("港幣", "HKD"), ("港元", "HKD"),
            ("¥", ambYen), ("￥", ambYen), ("$", ambDollar), ("＄", ambDollar), ("元", ambYuan),
        ]
        return raw.map { Symbol(chars: Array($0.0), key: $0.1) }.sorted { $0.chars.count > $1.chars.count }
    }()
    /// 금액 '앞'에는 붙지 않는 표기(뒤에서만 읽는다): "20엔 3유로"에서 '엔'이 뒤 숫자의 접두 기호로 읽히는 오인을 막는다.
    private static let suffixOnlySymbols: Set<String> = ["円", "圓", "엔", "元", "日元", "日圆", "日圓", "港元", "zł", "Kč"]

    private static let words: [Word] = {
        func l(_ s: String, _ k: String) -> (String, String, WordKind) { (s, k, .latin) }
        func h(_ s: String, _ k: String) -> (String, String, WordKind) { (s, k, .hangul) }
        func k(_ s: String, _ key: String) -> (String, String, WordKind) { (s, key, .katakana) }
        func c(_ s: String, _ key: String) -> (String, String, WordKind) { (s, key, .other) }
        let raw: [(String, String, WordKind)] = [
            l("new zealand dollars", "NZD"), l("new zealand dollar", "NZD"), l("hong kong dollars", "HKD"), l("hong kong dollar", "HKD"),
            l("singapore dollars", "SGD"), l("singapore dollar", "SGD"), l("canadian dollars", "CAD"), l("canadian dollar", "CAD"),
            l("australian dollars", "AUD"), l("australian dollar", "AUD"), l("new taiwan dollars", "TWD"), l("taiwan dollars", "TWD"),
            l("u.s. dollars", "USD"), l("us dollars", "USD"), l("us dollar", "USD"), l("american dollars", "USD"),
            l("philippine pesos", "PHP"), l("philippine peso", "PHP"), l("mexican pesos", "MXN"), l("mexican peso", "MXN"),
            l("argentine pesos", "ARS"), l("argentine peso", "ARS"), l("chilean pesos", "CLP"), l("chilean peso", "CLP"),
            l("colombian pesos", "COP"), l("colombian peso", "COP"),
            l("indian rupees", "INR"), l("indian rupee", "INR"), l("pakistani rupees", "PKR"), l("swiss francs", "CHF"), l("swiss franc", "CHF"),
            l("british pounds", "GBP"), l("british pound", "GBP"), l("pounds sterling", "GBP"), l("pound sterling", "GBP"),
            l("turkish lira", "TRY"), l("thai baht", "THB"), l("chinese yuan", "CNY"), l("renminbi", "CNY"),
            l("dollars", ambDollar), l("dollar", ambDollar), l("euros", "EUR"), l("euro", "EUR"), l("yen", "JPY"),
            l("yuan", ambYuan), l("baht", "THB"), l("rupiah", "IDR"), l("ringgit", "MYR"), l("zloty", "PLN"),
            l("rubles", "RUB"), l("roubles", "RUB"), l("ruble", "RUB"), l("pesos", ambPeso), l("peso", ambPeso),
            l("rupees", ambRupee), l("rupee", ambRupee), l("francs", ambFranc), l("franc", ambFranc),
            h("미국 달러", "USD"), h("캐나다 달러", "CAD"), h("호주 달러", "AUD"), h("오스트레일리아 달러", "AUD"), h("뉴질랜드 달러", "NZD"),
            h("홍콩 달러", "HKD"), h("싱가포르 달러", "SGD"), h("대만 달러", "TWD"), h("신타이완 달러", "TWD"), h("달러", ambDollar),
            h("필리핀 페소", "PHP"), h("멕시코 페소", "MXN"), h("아르헨티나 페소", "ARS"), h("칠레 페소", "CLP"), h("콜롬비아 페소", "COP"),
            h("페소", ambPeso), h("인도 루피", "INR"), h("파키스탄 루피", "PKR"), h("루피아", "IDR"), h("루피", ambRupee),
            h("스위스 프랑", "CHF"), h("프랑", ambFranc), h("영국 파운드", "GBP"), h("파운드", "GBP"), h("유로", "EUR"),
            h("위안", ambYuan), h("바트", "THB"), h("링깃", "MYR"), h("루블", "RUB"), h("엔", "JPY"),
            k("米ドル", "USD"), k("豪ドル", "AUD"), k("カナダドル", "CAD"), k("香港ドル", "HKD"), k("シンガポールドル", "SGD"),
            k("ニュージーランドドル", "NZD"), k("新台湾ドル", "TWD"), k("台湾ドル", "TWD"), k("フィリピンペソ", "PHP"), k("ドル", ambDollar),
            k("ユーロ", "EUR"), k("ポンド", "GBP"), k("バーツ", "THB"), k("ペソ", ambPeso), k("ルピア", "IDR"), k("リンギット", "MYR"),
            c("美元", "USD"), c("美金", "USD"), c("欧元", "EUR"), c("歐元", "EUR"), c("英镑", "GBP"), c("英鎊", "GBP"),
            c("泰铢", "THB"), c("泰銖", "THB"), c("澳元", "AUD"), c("加元", "CAD"), c("新加坡元", "SGD"),
        ]
        return raw.map { Word(chars: Array($0.0), key: $0.1, kind: $0.2) }.sorted { $0.chars.count > $1.chars.count }
    }()

    private static let hangulParticles: Set<Character> = Set("은는이가을를에의도로과와만화께")
    private static let unitValues: [Character: Double] = ["万": 1e4, "萬": 1e4, "億": 1e8, "亿": 1e8, "兆": 1e12, "千": 1e3,
                                                         "만": 1e4, "억": 1e8, "조": 1e12, "천": 1e3]
    private static let groupSpaces: Set<Character> = [" ", "\u{00A0}", "\u{202F}", "\u{2009}", "\u{2007}"]

    // MARK: 문자 도우미

    private static func digit(_ c: Character?) -> Int? {
        guard let c, c.unicodeScalars.count == 1, let u = c.unicodeScalars.first else { return nil }
        switch u.value {
        case 48...57: return Int(u.value) - 48
        case 0xFF10...0xFF19: return Int(u.value) - 0xFF10
        default: return nil
        }
    }
    private static func isDigit(_ c: Character?) -> Bool { digit(c) != nil }
    private static func isLatin(_ c: Character?) -> Bool {
        guard let c, c.unicodeScalars.count == 1, let u = c.unicodeScalars.first?.value else { return false }
        return (65...90).contains(u) || (97...122).contains(u)
    }
    private static func isLetterOrDigit(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber } ?? false }
    private static func isSpace(_ c: Character?) -> Bool { c.map { groupSpaces.contains($0) } ?? false }
    private static func isHangul(_ c: Character?) -> Bool {
        guard let u = c?.unicodeScalars.first?.value else { return false }
        return (0xAC00...0xD7A3).contains(u)
    }
    private static func isKatakana(_ c: Character?) -> Bool {
        guard let u = c?.unicodeScalars.first?.value else { return false }
        return (0x30A1...0x30FA).contains(u)
    }
    private static func at(_ t: [Character], _ i: Int) -> Character? { i >= 0 && i < t.count ? t[i] : nil }
    private static func matches(_ t: [Character], at i: Int, _ pattern: [Character]) -> Bool {
        guard i >= 0, i + pattern.count <= t.count else { return false }
        for (k, ch) in pattern.enumerated() where t[i + k] != ch { return false }
        return true
    }
    private static func isUpperISO(_ s: ArraySlice<Character>) -> Bool {
        s.count == 3 && s.allSatisfy { $0.isASCII && $0.isUppercase && $0.isLetter }
    }

    // MARK: 모호 표기 해석

    private static func resolveAmbiguous(_ key: String, _ ctx: CurrencyContext, word: Bool, kanaNear: Bool) -> String? {
        let country = ctx.country
        switch key {
        case ambDollar:
            if country == "PH" { return nil }
            if let code = countryDollar[country] { return code }
            if usdDefaultLangs.contains(ctx.lang) {
                if ctx.lang == "zh", ctx.script == "hant", !word { return nil }
                return "USD"
            }
            return nil
        case ambYen:
            if ctx.lang == "ja" || country == "JP" || ctx.kana || kanaNear { return "JPY" }
            if (ctx.lang == "zh" && ctx.script == "hans") || country == "CN" { return "CNY" }
            return nil
        case ambYuan:
            if country == "TW" || (ctx.lang == "zh" && ctx.script == "hant" && country != "HK") { return "TWD" }
            if country == "HK" { return "HKD" }
            if ctx.lang == "ko" || ctx.lang == "ja" || ctx.lang == "zh" || country == "CN" { return "CNY" }
            return word ? "CNY" : nil
        case ambPeso: return countryPeso[country] // 'peso'만으로는 필리핀으로 단정하지 않는다
        case ambRupee: return countryRupee[country]
        case ambFranc: return country == "CH" || country == "LI" ? "CHF" : nil
        default: return nil
        }
    }

    // MARK: 숫자 읽기

    private static func scanNumber(_ t: [Character], _ i: Int, hint: String?, ctx: CurrencyContext) -> (end: Int, value: Double)? {
        var runs: [String] = []
        var seps: [Character] = []
        var p = i
        while true {
            var q = p
            var digits = ""
            while q < t.count, let d = digit(t[q]) { digits.append(String(d)); q += 1 }
            runs.append(digits)
            p = q
            guard let sep = at(t, p), isDigit(at(t, p + 1)),
                  sep == "," || sep == "." || sep == "'" || sep == "\u{2019}" || isSpace(sep) else { break }
            if isSpace(sep) {
                var k = p + 1, n = 0
                while k < t.count, isDigit(t[k]) { n += 1; k += 1 }
                let prev = runs[runs.count - 1]
                if n != 3 || (runs.count == 1 ? prev.count > 3 : prev.count != 3) { break }
            }
            seps.append(isSpace(sep) ? " " : (sep == "\u{2019}" ? "'" : sep))
            p += 1
        }
        let end = p
        func number(_ s: String) -> Double? { Double(s) }
        if runs.count == 1 { return number(runs[0]).map { (end, $0) } }
        let last = seps[seps.count - 1]
        let lastRun = runs[runs.count - 1]
        func grouped(_ list: [String], _ kind: Character) -> Bool {
            guard let first = list.first, (1...3).contains(first.count) else { return false }
            let rest = list.dropFirst()
            if rest.allSatisfy({ $0.count == 3 }) { return true }
            return kind == "," && rest.count >= 2 && rest.last?.count == 3 && rest.dropLast().allSatisfy { $0.count == 2 }
        }
        let kinds = Set(seps)
        if kinds.count == 1 {
            if seps.count >= 2 || last == " " || last == "'" {
                return grouped(runs, last) ? number(runs.joined()).map { (end, $0) } : nil
            }
            let decimal = number(runs[0] + "." + lastRun).map { (end, $0) }
            let thousands = number(runs[0] + lastRun).map { (end, $0) }
            if lastRun.count != 3 || runs[0] == "0" || runs[0].count > 3 { return decimal }
            if last == ".", let hint, threeDecimal.contains(hint) { return decimal }
            if last == "," {
                let leaning = ctx.decimalComma && !(hint.map { zeroDecimal.contains($0) || dotGrouping.contains($0) } ?? false)
                return leaning ? nil : thousands
            }
            if let hint, zeroDecimal.contains(hint) || dotGrouping.contains(hint) { return thousands }
            if ctx.decimalComma { return thousands }
            return nil // 영어권 '1.000 USD'는 천 단위/소수를 구분할 수 없으므로 건너뜀
        }
        guard last == "," || last == "." else { return nil }
        let groupSeps = Array(seps.dropLast())
        guard Set(groupSeps).count == 1, groupSeps[0] != last else { return nil }
        let head = Array(runs.dropLast())
        guard grouped(head, groupSeps[0]) else { return nil }
        return number(head.joined() + "." + lastRun).map { (end, $0) }
    }

    private static func applyCJKUnits(_ t: [Character], _ n: (end: Int, value: Double)) -> (end: Int, value: Double, unit: Bool) {
        var p = n.end
        guard let first = at(t, p), let u = unitValues[first] else { return (n.end, n.value, false) }
        var total = n.value * u
        var lastUnit = u
        p += 1
        while true {
            var q = p
            var digits = ""
            while q < t.count, isDigit(t[q]) || (t[q] == "," && isDigit(at(t, q + 1))) {
                if let d = digit(t[q]) { digits.append(String(d)) }
                q += 1
            }
            guard !digits.isEmpty, let value = Double(digits) else { break }
            if let ch = at(t, q), let unit = unitValues[ch], unit < lastUnit {
                total += value * unit
                lastUnit = unit
                p = q + 1
                continue
            }
            if unitValues[at(t, q) ?? " "] == nil, lastUnit >= 1e4, digits.count <= 4, value < lastUnit {
                total += value
                p = q
            }
            break
        }
        return (p, total, true)
    }

    private static func applyEnglishUnits(_ t: [Character], _ n: (end: Int, value: Double, unit: Bool)) -> (end: Int, value: Double, unit: Bool) {
        var p = n.end
        if isSpace(at(t, p)) { p += 1 }
        var word = ""
        var q = p
        while q < t.count, isLatin(t[q]), word.count < 8 { word.append(t[q]); q += 1 }
        guard !word.isEmpty, !isLatin(at(t, q)) else { return n }
        let mult: [String: Double] = ["trillion": 1e12, "tn": 1e12, "billion": 1e9, "bn": 1e9, "b": 1e9, "million": 1e6, "mn": 1e6,
                                      "m": 1e6, "thousand": 1e3, "k": 1e3]
        guard let m = mult[word.lowercased()] else { return n }
        return (q, n.value * m, true)
    }

    // MARK: 통화 표기

    private static func boundaryBefore(_ t: [Character], _ i: Int) -> Bool { !isLatin(at(t, i - 1)) }

    private static func findPrefix(_ t: [Character], _ s: Int) -> (start: Int, key: String, iso: Bool)? {
        var e = s
        if e > 0, isSpace(t[e - 1]) { e -= 1 }
        if e > 0, isSpace(t[e - 1]) { return nil }
        for sym in symbols {
            if suffixOnlySymbols.contains(String(sym.chars)) { continue }
            let start = e - sym.chars.count
            guard start >= 0, matches(t, at: start, sym.chars) else { continue }
            if isLatin(sym.chars[0]), !boundaryBefore(t, start) { continue }
            return (start, sym.key, false)
        }
        if e >= 3 {
            let slice = t[(e - 3)..<e]
            let code = String(slice)
            if isUpperISO(slice), fiat.contains(code), boundaryBefore(t, e - 3) { return (e - 3, code, true) }
        }
        return nil
    }

    private static func findSuffix(_ t: [Character], _ e: Int) -> (end: Int, key: String, iso: Bool, word: Bool)? {
        var p = e
        if isSpace(at(t, p)) { p += 1 }
        guard p < t.count else { return nil }
        if p + 3 <= t.count {
            let slice = t[p..<(p + 3)]
            let code = String(slice)
            if isUpperISO(slice), fiat.contains(code), !isLetterOrDigit(at(t, p + 3)) { return (p + 3, code, true, true) }
        }
        let rest = Array(t[p..<min(t.count, p + 24)])
        let lower = Array(String(rest).lowercased())
        for w in words {
            let count = w.chars.count
            if w.kind == .latin {
                guard lower.count >= count, Array(lower[0..<count]) == w.chars else { continue }
                if isLatin(at(rest, count)) { continue }
            } else {
                guard rest.count >= count, Array(rest[0..<count]) == w.chars else { continue }
                let after = at(rest, count)
                if w.kind == .hangul, isHangul(after), !(after.map { hangulParticles.contains($0) } ?? false) { continue }
                if w.kind == .katakana, isKatakana(after) { continue }
            }
            return (p + count, w.key, false, true)
        }
        for sym in symbols {
            let s = String(sym.chars)
            if s == "$" || s == "＄" { continue }
            let count = sym.chars.count
            guard rest.count >= count, Array(rest[0..<count]) == sym.chars else { continue }
            let after = at(rest, count)
            if isLatin(sym.chars[0]), isLatin(after) { continue }
            if (s == "엔" || s == "元"), isHangul(after), !(after.map { hangulParticles.contains($0) } ?? false) { continue }
            return (p + count, sym.key, false, false)
        }
        if rest.count >= 2, rest[0] == "F", rest[1] == "t", !isLatin(at(rest, 2)) { return (p + 2, "HUF", false, false) }
        return nil
    }

    /// 명시 ISO 코드가 돈이 아닌 문맥(PHP 버전, "TOP 10 products", "5 AMD Ryzen")인지.
    private static func nonMoneyISO(_ t: [Character], code: String, numStart: Int, numEnd: Int, prefixSide: Bool, codeEnd: Int) -> Bool {
        if prefixSide {
            let raw = String(t[numStart..<numEnd])
            if code == "PHP", raw.range(of: #"^[5-8](\.\d+){0,2}$"#, options: .regularExpression) != nil { return true }
            if wordlikeCodes.contains(code), raw.range(of: #"^(3|5|10|20|25|50|100)$"#, options: .regularExpression) != nil,
               String(t[numEnd..<min(t.count, numEnd + 20)]).range(of: #"^\s+[A-Za-z]{3,}"#, options: .regularExpression) != nil { return true }
            return false
        }
        return wordlikeCodes.contains(code)
            && String(t[min(codeEnd, t.count)..<min(t.count, codeEnd + 20)]).range(of: #"^\s+[A-Z][A-Za-z]+"#, options: .regularExpression) != nil
    }

    private static func isoBefore(_ t: [Character], _ start: Int) -> (start: Int, code: String)? {
        var e = start
        if e > 0, isSpace(t[e - 1]) { e -= 1 }
        guard e >= 3 else { return nil }
        let slice = t[(e - 3)..<e]
        let code = String(slice)
        if isUpperISO(slice), fiat.contains(code), boundaryBefore(t, e - 3) { return (e - 3, code) }
        return nil
    }

    private static func scanEnd(_ t: [Character], _ i: Int) -> Int {
        var p = i
        while p < t.count, isDigit(t[p]) || ((t[p] == "," || t[p] == "." || t[p] == "'" || t[p] == "\u{2019}" || isSpace(t[p])) && isDigit(at(t, p + 1))) { p += 1 }
        return p
    }

    private static let krwAfter = try! NSRegularExpression(
        pattern: #"^\s*[\(（\[]?\s*(?:약|≈|~|about|approx\.?)?\s*[\d,\.]+\s*(?:만|억|천)?\s*(?:원|KRW)"#, options: [.caseInsensitive])
    private static let rangeAfter = try! NSRegularExpression(pattern: #"^\s*[-–—~〜～]\s*[\d０-９]"#)

    private static func matchesStart(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, options: [.anchored], range: NSRange(s.startIndex..., in: s)) != nil
    }

    // MARK: 공개 API

    /// 빠른 사전 검사(OCR 줄이 환산 후보일 수 있는지): 숫자와 통화 단서가 함께 있을 때만 true. 환율·문맥은 필요 없다.
    static func mightContainAmount(_ text: String) -> Bool {
        guard text.contains(where: { digit($0) != nil }) else { return false }
        let symbolsHint: Set<Character> = ["$", "€", "£", "¥", "￥", "＄", "₱", "₹", "฿", "₫", "₽", "₺", "₪", "₴", "₦", "₭", "₸", "₾", "₼", "₡", "₲", "₵",
                                           "円", "圓", "元", "엔", "달", "러", "유", "로", "파", "운", "드", "위", "안", "바", "트", "페", "소", "ド", "ル", "ユ", "ー"]
        if text.contains(where: { symbolsHint.contains($0) }) { return true }
        let lower = text.lowercased()
        for hint in ["dollar", "euro", "yen", "peso", "baht", "yuan", "rupee", "rupiah", "ringgit", "pound", "renminbi", "zloty", "ruble", "zł", "kč", "rp", "rm", "php"]
        where lower.contains(hint) { return true }
        let chars = Array(text)
        var run = 0
        for ch in chars {
            if ch.isASCII, ch.isUppercase, ch.isLetter { run += 1; if run >= 3 { return true } } else { run = 0 }
        }
        return false
    }

    /// text 안의 외국 금액. krwPer는 1통화 단위당 원화 표(없으면 label은 nil). 같은 규칙의 JS 구현은 fx.js의 findAmounts.
    static func findAmounts(_ text: String, context: CurrencyContext, krwPer: [String: Double]) -> (mentions: [CurrencyMention], skipped: Int) {
        let t = Array(text)
        var mentions: [CurrencyMention] = []
        var skipped = 0
        guard t.count >= 2, t.contains(where: { isDigit($0) }) else { return ([], 0) }
        var i = 0
        while i < t.count {
            guard isDigit(t[i]) else { i += 1; continue }
            let before = at(t, i - 1)
            if let before, isDigit(before) || (["." , ",", "-", "/", ":", "·"].contains(before) && isDigit(at(t, i - 2))) {
                while i < t.count, isDigit(t[i]) || [".", ",", ":", "/", "-"].contains(t[i]) { i += 1 }
                continue
            }
            let prefix = findPrefix(t, i)
            if prefix == nil, isLatin(before) {
                i += 1
                while i < t.count, isDigit(t[i]) { i += 1 }
                continue
            }
            let prefixHint = prefix.flatMap { $0.key.hasPrefix("AMB_") ? nil : $0.key }
            var number = scanNumber(t, i, hint: prefixHint, ctx: context)
            if number == nil {
                let probeEnd = scanEnd(t, i)
                let probe = findSuffix(t, probeEnd)
                let hint = probe.flatMap { $0.key.hasPrefix("AMB_") ? nil : $0.key }
                number = hint.flatMap { scanNumber(t, i, hint: $0, ctx: context) }
            } else if prefixHint == nil, let probe = findSuffix(t, number!.end), !probe.key.hasPrefix("AMB_"),
                      let again = scanNumber(t, i, hint: probe.key, ctx: context) {
                number = again
            }
            guard let found = number else {
                let skipEnd = scanEnd(t, i)
                if prefix != nil || findSuffix(t, skipEnd) != nil { skipped += 1 }
                i = max(skipEnd, i + 1)
                continue
            }
            if let tail = at(t, found.end), [".", ",", "/", "-", ":"].contains(tail), isDigit(at(t, found.end + 1)) {
                i = found.end + 1
                while i < t.count, isDigit(t[i]) || [".", ",", ":", "/", "-"].contains(t[i]) { i += 1 }
                continue
            }
            var scaled = applyCJKUnits(t, found)
            if prefix != nil, !scaled.unit { scaled = applyEnglishUnits(t, scaled) }
            guard scaled.value.isFinite, scaled.value > 0, scaled.value < 1e15 else { i = max(scaled.end, i + 1); continue }

            let suffix = findSuffix(t, scaled.end)
            var key: String?
            var startIdx = prefix?.start ?? i
            var endIdx = scaled.end
            var wordForm = false
            if let suffix, suffix.iso {
                key = suffix.key; endIdx = suffix.end; wordForm = true
            } else if let prefix, prefix.iso {
                key = prefix.key
            } else if let prefix {
                key = prefix.key
                if let suffix, !suffix.iso, suffix.key == prefix.key || (prefix.key == "CNY" && suffix.key == ambYuan) { endIdx = suffix.end }
                if let suffix, !suffix.key.hasPrefix("AMB_"), prefix.key.hasPrefix("AMB_"), suffix.word { key = suffix.key; endIdx = suffix.end }
            } else if let suffix {
                key = suffix.key; endIdx = suffix.end; wordForm = suffix.word
            }
            guard var currency = key else { i = max(scaled.end, i + 1); continue }
            if let suffix, suffix.iso {
                if nonMoneyISO(t, code: currency, numStart: i, numEnd: scaled.end, prefixSide: false, codeEnd: endIdx) { i = max(endIdx, i + 1); continue }
            } else if let prefix, prefix.iso,
                      nonMoneyISO(t, code: currency, numStart: i, numEnd: scaled.end, prefixSide: true, codeEnd: endIdx) { i = max(endIdx, i + 1); continue }
            if let prefix, !prefix.iso, !(suffix?.iso ?? false), let lead = isoBefore(t, prefix.start) {
                currency = lead.code
                startIdx = lead.start
            }
            if currency.hasPrefix("AMB_") {
                let nearStart = max(0, startIdx - 24), nearEnd = min(t.count, endIdx + 24)
                let kanaNear = t[nearStart..<nearEnd].contains { $0.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) } }
                guard let resolved = resolveAmbiguous(currency, context, word: wordForm, kanaNear: kanaNear) else {
                    skipped += 1
                    i = max(endIdx, i + 1)
                    continue
                }
                currency = resolved
            }
            guard currency != "KRW", fiat.contains(currency) else { i = max(endIdx, i + 1); continue }
            let after = String(t[endIdx..<min(t.count, endIdx + 28)])
            if matchesStart(krwAfter, after) { i = max(endIdx, i + 1); continue }
            if matchesStart(rangeAfter, after) { skipped += 1; i = max(endIdx, i + 1); continue }
            var krw: Double?
            var label: String?
            if let per = krwPer[currency], per.isFinite, per > 0 {
                krw = scaled.value * per
                label = formatKRW(scaled.value * per)
            }
            mentions.append(CurrencyMention(start: startIdx, end: endIdx, code: currency, amount: scaled.value, krw: krw, label: label))
            i = max(endIdx, i + 1)
        }
        return (mentions, skipped)
    }

    /// 원화 표시 문자열("약 138,600원"). 너무 작은 값은 nil.
    static func formatKRW(_ value: Double) -> String? {
        guard value.isFinite, value > 0 else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        let rounded: Double
        if value >= 100 { formatter.maximumFractionDigits = 0; rounded = value.rounded() }
        else if value >= 1 { formatter.maximumFractionDigits = 1; rounded = (value * 10).rounded() / 10 }
        else if value >= 0.01 { formatter.maximumFractionDigits = 2; rounded = (value * 100).rounded() / 100 }
        else { return nil }
        guard let s = formatter.string(from: NSNumber(value: rounded)) else { return nil }
        return "약 \(s)원"
    }

    /// 환산 후보가 있는 글자를 [(조각, 주석 여부)]로 나눈다. 주석 조각은 "(약 N원)"이고 앞 조각은 금액 바로 뒤까지다.
    static func segments(of text: String, context: CurrencyContext, krwPer: [String: Double]) -> [(text: String, isAnnotation: Bool)] {
        let mentions = findAmounts(text, context: context, krwPer: krwPer).mentions.filter { $0.label != nil }
        guard !mentions.isEmpty else { return [(text, false)] }
        let t = Array(text)
        var result: [(String, Bool)] = []
        var cursor = 0
        for mention in mentions {
            result.append((String(t[cursor..<mention.end]), false))
            result.append(("(\(mention.label ?? ""))", true))
            cursor = mention.end
        }
        if cursor < t.count { result.append((String(t[cursor...]), false)) }
        return result
    }
}

// MARK: - 이미지 말풍선 배치(OCR 줄 → 금액 칸, 말풍선 위치)

struct CurrencyBubbleSpec: Equatable {
    /// "약 138,600원"
    let label: String
    /// 외국 금액이 차지하는 칸. 좌표계는 호출자가 넘긴 줄 상자와 같다.
    let price: CGRect
}

enum CurrencyBubbleLayout {
    /// 공백 아닌 인식 글자마다 글자 상자 하나를 돌려준다(개수 = 공백 제외 글자 수). 순서대로 글자가 맞는 상자만 쓰고, 상자를 못 찾은 글자는
    /// 앞뒤 맞은 상자 사이를 보간한다. 맞은 글자가 60% 미만이면 nil(호출자가 줄 단위 추정으로 대신한다).
    static func alignedGlyphBoxes(text: String, glyphBoxes: [CGRect], glyphTexts: [String]) -> [CGRect]? {
        let letters = text.filter { !$0.isWhitespace }
        guard !letters.isEmpty, !glyphBoxes.isEmpty, glyphBoxes.count == glyphTexts.count else { return nil }
        var boxes = [CGRect?](repeating: nil, count: letters.count)
        var j = 0
        for (k, ch) in letters.enumerated() where j < glyphTexts.count && glyphTexts[j] == String(ch) {
            boxes[k] = glyphBoxes[j]
            j += 1
        }
        guard Double(j) >= Double(letters.count) * 0.6 else { return nil }
        var result: [CGRect] = []
        for k in boxes.indices {
            if let box = boxes[k] { result.append(box); continue }
            let prev = (0..<k).reversed().first { boxes[$0] != nil }
            let next = ((k + 1)..<boxes.count).first { boxes[$0] != nil }
            switch (prev, next) {
            case let (p?, n?):
                let t = CGFloat(k - p) / CGFloat(n - p)
                let a = boxes[p]!, b = boxes[n]!
                result.append(CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
                                     width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t))
            case let (p?, nil): result.append(boxes[p]!)
            case let (nil, n?): result.append(boxes[n]!)
            default: return nil
            }
        }
        return result
    }

    /// 줄 하나에서 환산할 금액마다 금액 칸을 구한다.
    /// - 글자 상자(glyphBoxes/glyphTexts)가 인식 원문의 공백 아닌 글자와 순서대로 맞으면 그 금액 구간 글자들의 합집합을 쓴다.
    /// - 맞지 않거나 글자 상자가 없으면 줄 상자를 글자 수 비율로 나눈 구간(같은 줄의 여러 금액을 따로 구분)을 쓴다.
    /// - readingDownIsIncreasingY: 세로쓰기 줄에서 읽는 방향이 y 증가인지(y 아래 방향 좌표계) 감소인지.
    static func specs(text: String, lineBox: CGRect, glyphBoxes: [CGRect], glyphTexts: [String], readingDownIsIncreasingY: Bool,
                      context: CurrencyContext, krwPer: [String: Double]) -> [CurrencyBubbleSpec] {
        guard CurrencyParser.mightContainAmount(text), lineBox.width > 0, lineBox.height > 0 else { return [] }
        let mentions = CurrencyParser.findAmounts(text, context: context, krwPer: krwPer).mentions.filter { $0.label != nil }
        guard !mentions.isEmpty else { return [] }
        let chars = Array(text)
        let nonSpace = chars.enumerated().filter { !$0.element.isWhitespace }
        let aligned = alignedGlyphBoxes(text: text, glyphBoxes: glyphBoxes, glyphTexts: glyphTexts)
        func nonSpaceCount(before index: Int) -> Int { nonSpace.filter { $0.offset < index }.count }
        let vertical = lineBox.height > lineBox.width * 1.5
        // 줄바꿈이 있는 문단은 글자 상자가 없을 때 줄 단위로 나눠 읽는다(문단 전체 크기로 비례 추정하지 않는다).
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { Array($0) }
        var lineStarts: [Int] = []
        var offset = 0
        for line in lines { lineStarts.append(offset); offset += line.count + 1 }
        var result: [CurrencyBubbleSpec] = []
        for mention in mentions {
            guard let label = mention.label else { continue }
            let a = nonSpaceCount(before: mention.start), b = nonSpaceCount(before: mention.end)
            var price: CGRect?
            if let aligned, b > a, b <= aligned.count {
                let boxes = Array(aligned[a..<b])
                let union = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
                if union.width > 0, union.height > 0, union.intersects(lineBox.insetBy(dx: -0.02, dy: -0.02)) { price = union }
            }
            if price == nil {
                let lineIndex = max(0, (lineStarts.lastIndex { $0 <= mention.start }) ?? 0)
                let count = max(1, lines.count)
                let lineLength = CGFloat(max(1, lines.isEmpty ? chars.count : lines[lineIndex].count))
                let local = lineStarts.isEmpty ? 0 : lineStarts[lineIndex]
                let from = CGFloat(mention.start - local) / lineLength, to = min(1, CGFloat(mention.end - local) / lineLength)
                if vertical {
                    // 세로쓰기: 줄 번호는 가로 방향, 글자는 세로로 읽는다.
                    let (lo, hi) = readingDownIsIncreasingY ? (from, to) : (1 - to, 1 - from)
                    let columnWidth = lineBox.width / CGFloat(count)
                    price = CGRect(x: lineBox.maxX - columnWidth * CGFloat(lineIndex + 1), y: lineBox.minY + lineBox.height * lo,
                                   width: columnWidth, height: lineBox.height * (hi - lo))
                } else {
                    let rowHeight = lineBox.height / CGFloat(count)
                    let top = readingDownIsIncreasingY ? lineBox.minY + rowHeight * CGFloat(lineIndex)
                                                       : lineBox.maxY - rowHeight * CGFloat(lineIndex + 1)
                    price = CGRect(x: lineBox.minX + lineBox.width * from, y: top, width: lineBox.width * (to - from), height: rowHeight)
                }
            }
            if let price { result.append(CurrencyBubbleSpec(label: label, price: price)) }
        }
        return result
    }

    /// 말풍선을 금액 바로 아래(없으면 위, 그것도 없으면 경계 안쪽)에 놓는다. 다른 말풍선과 겹치지 않는 자리를 먼저 고르고,
    /// 경계에 맞추더라도 금액 칸을 가리지 않는 자리를 우선한다. belowIsLargerY: y가 커질수록 아래인 좌표계(SwiftUI·뒤집힌 뷰).
    static func place(size: CGSize, price: CGRect, in bounds: CGRect, occupied: [CGRect], belowIsLargerY: Bool) -> CGRect {
        let gap: CGFloat = 2
        let maxX = bounds.maxX - size.width - 1
        let x = maxX >= bounds.minX + 1 ? min(max(price.minX, bounds.minX + 1), maxX) : bounds.minX
        func rect(_ y: CGFloat) -> CGRect { CGRect(x: x, y: y, width: size.width, height: size.height) }
        let below = belowIsLargerY ? price.maxY + gap : price.minY - gap - size.height
        let above = belowIsLargerY ? price.minY - gap - size.height : price.maxY + gap
        let edge = belowIsLargerY ? bounds.maxY - size.height - 1 : bounds.minY + 1
        let candidates = [rect(below), rect(above), rect(edge)]
        func inside(_ r: CGRect) -> Bool { r.minY >= bounds.minY && r.maxY <= bounds.maxY && r.minX >= bounds.minX && r.maxX <= bounds.maxX }
        if let free = candidates.first(where: { candidate in inside(candidate) && !occupied.contains(where: { $0.intersects(candidate) }) }) { return free }
        if let clear = candidates.first(where: { inside($0) && !$0.intersects(price) }) { return clear }
        var fallback = candidates[0]
        fallback.origin.y = min(max(fallback.origin.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height))
        return fallback
    }
}
