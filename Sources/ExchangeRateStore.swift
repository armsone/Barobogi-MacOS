import AppKit
import Foundation
import Network
import NaturalLanguage
import Observation
import SwiftUI

// 원화 환산 환율 저장소(메인 앱 전용). 번역 내용과는 완전히 별도다.
// - 고정된 공개 주소 3곳에서 익명 GET만 한다. 페이지/메일/화면 글자·이미지·주소·사용자 식별자는 보내지 않는다.
//   기본: https://api.exchangerate.dev/v1/latest?base=USD (키 없는 무료 데이터, 약 15분 지연 — 실시간이 아님)
//   대체: jsDelivr의 fawazahmed0 통화 API → Cloudflare Pages 사본(일별).
// - 마지막으로 검증된 환율만 UserDefaults에 저장한다(실패·불량 응답은 덮어쓰지 않음). 번역된 내용은 저장하지 않는다.
// - 시작·앱 활성화·연결 복귀·번역 시작 때 갱신한다(번역은 기다리지 않는다). 겹치는 요청은 하나로 합치고,
//   엔드포인트마다 짧은 제한 시간과 제한된 재시도를 둔다.
// - 교차 환산: 금액 × KRW ÷ 해당 통화(USD=1). 고정/내장 환율은 없다.

extension Notification.Name {
    /// 새 환율이 검증·저장됐을 때(주 스레드).
    static let exchangeRatesDidUpdate = Notification.Name("ExchangeRatesDidUpdate")
}

@MainActor
@Observable
final class ExchangeRateStore {
    static let shared = ExchangeRateStore()

    static let attributionText = "Rates by Exchangerate.dev"
    /// 제공사 약관상 출처 표기 링크.
    static let attributionURL = URL(string: "https://exchangerate.dev")!
    static let needsFetchMessage = "환율을 한 번 받아야 원화 환산을 사용할 수 있습니다"

    enum Provider: String, Codable {
        case exchangerateDev = "exchangerate.dev"
        case fawaz = "fawazahmed0"
    }

    enum Reason { case launch, foreground, reconnect, translationStart }

    struct Cache: Codable {
        var provider: Provider
        var rates: [String: Double]
        /// 제공사가 알려준 관측(기준) 시각. 우리가 받아 온 시각(fetchedAt)과 다르다.
        var sourceTime: Date?
        var sourceDate: String?
        var fetchedAt: Date
        var stale: Bool
    }

    /// 기본 제공사(exchangerate.dev) 응답.
    private(set) var primary: Cache?
    /// 일별 보조 스냅샷(fawazahmed0): 주 응답에 없는 통화에만 쓰고, 환산은 이 스냅샷 자신의 KRW로 한다.
    private(set) var daily: Cache?
    /// 일별 보조에서 가져온 통화 수(주 응답이 있을 때만 센다).
    private(set) var supplementCount = 0
    var cache: Cache? { primary ?? daily }
    /// 1통화 단위당 원화(KRW). 환율을 받은 적이 없으면 비어 있다.
    private(set) var krwPer: [String: Double] = [:]
    private(set) var lastAttempt: Date?
    private(set) var lastAttemptSucceeded = true

    @ObservationIgnored private var inflight: Task<Void, Never>?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var isOnline: Bool?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var activeObserver: NSObjectProtocol?

    private static let cacheKey = "FXRates.cache.v1"
    private static let dailyKey = "FXRates.daily.v1"
    private static let attemptKey = "FXRates.lastAttempt.v1"
    private static let attemptOKKey = "FXRates.lastAttemptOK.v1"
    private static let refreshInterval: TimeInterval = 15 * 60
    private static let noCacheRetry: TimeInterval = 60
    private static let savedAfter: TimeInterval = 20 * 60
    private nonisolated static let endpointTimeout: TimeInterval = 6

    private nonisolated static let primaryURL = URL(string: "https://api.exchangerate.dev/v1/latest?base=USD")!
    private nonisolated static let fallbackURLs = [
        URL(string: "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.min.json")!,
        URL(string: "https://latest.currency-api.pages.dev/v1/currencies/usd.min.json")!,
    ]

    private init() {
        let defaults = UserDefaults.standard
        func stored(_ key: String) -> Cache? {
            guard let data = defaults.data(forKey: key), var value = try? JSONDecoder().decode(Cache.self, from: data),
                  let rates = Self.normalize(value.rates) else { return nil }
            value.rates = rates
            return value
        }
        // 이전 버전은 일별 응답을 주 슬롯에 저장했다: 제공사별 슬롯으로 옮겨 읽는다.
        let first = stored(Self.cacheKey)
        primary = first?.provider == .exchangerateDev ? first : nil
        daily = stored(Self.dailyKey) ?? (first?.provider == .fawaz ? first : nil)
        rebuildTable()
        lastAttempt = defaults.object(forKey: Self.attemptKey) as? Date
        lastAttemptSucceeded = defaults.object(forKey: Self.attemptOKKey) as? Bool ?? true
    }

    // MARK: 상태

    var hasRates: Bool { cache != nil && !krwPer.isEmpty }
    /// 기본 제공사 데이터일 때만 출처 링크를 보인다.
    var attributionVisible: Bool { primary != nil }
    /// 주 응답에 없는 통화를 일별 보조에서 가져온 상태(출처·날짜가 섞임).
    var isMixed: Bool { primary != nil && supplementCount > 0 && daily != nil }

    /// 주 응답 표 + 주 응답에 없는 통화만 일별 표(각자 자신의 KRW 기준).
    private func rebuildTable() {
        var table = primary.map { Self.krwTable($0.rates) } ?? [:]
        var extra = 0
        if let daily {
            for (code, per) in Self.krwTable(daily.rates) where table[code] == nil {
                table[code] = per
                if primary != nil { extra += 1 }
            }
        }
        krwPer = table
        supplementCount = extra
    }

    /// 저장 환율 여부: 마지막 시도가 실패했거나 받은 지 20분이 넘었으면 '저장 환율'로 표시한다(온라인이라고 단정하지 않음).
    var isSavedRate: Bool {
        guard let cache else { return false }
        return !lastAttemptSucceeded || Date().timeIntervalSince(cache.fetchedAt) > Self.savedAfter
    }

    private static func display(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func sourceLabel(_ cache: Cache) -> String {
        if cache.provider == .fawaz { return cache.sourceDate.map { String($0.prefix(10)) } ?? "기준일 미상" }
        return cache.sourceTime.map(Self.display) ?? "기준 시각 미상"
    }

    /// 하단 상태 줄 문구(가격 주석과 별도). 받은 적이 없으면 안내 문구만 보여 주고 금액을 지어내지 않는다.
    var statusText: String {
        guard let cache else { return Self.needsFetchMessage }
        if isMixed, let primary, let daily {
            return "\(isSavedRate ? "저장 환율 · " : "")혼합 출처 · 주 기준 \(sourceLabel(primary)) · 일부 통화 일별 \(sourceLabel(daily)) · 참고용"
        }
        let name = cache.provider == .fawaz ? "Fawaz 일별 환율 " : ""
        let delay = cache.provider == .exchangerateDev ? " · 약 15분 지연" : " · 일 단위"
        return "\(isSavedRate ? "저장 환율 · " : "")\(name)기준 \(sourceLabel(cache))\(delay) · 참고용"
    }

    /// 툴팁/상세: 제공사, 제공사 기준 시각, 받은 시각(제공사 시각과 다름), 저장 여부.
    var detailText: String {
        guard let cache else { return Self.needsFetchMessage }
        if isMixed, let primary, let daily {
            return "혼합 출처: Exchangerate.dev(약 15분 지연) 기준 \(sourceLabel(primary)) + 주 응답에 없는 통화는 Fawaz 일별 \(sourceLabel(daily))(그 일별 자료 자체의 KRW로 환산)"
                + " · 받은 시각 \(Self.display(primary.fetchedAt))(제공사 시각과 다름)\(isSavedRate ? " · 저장 환율" : "") · 참고용, 실시간 아님"
        }
        let provider = cache.provider == .exchangerateDev ? "Exchangerate.dev(키 없는 무료 데이터, 약 15분 지연)" : "Fawaz Ahmed 통화 API(일별)"
        return "\(provider) · 제공사 기준 \(sourceLabel(cache)) · 받은 시각 \(Self.display(cache.fetchedAt))(제공사 시각과 다름)"
            + "\(isSavedRate ? " · 저장 환율" : "")\(cache.stale ? " · 제공사 표시: 지연" : "") · 참고용, 실시간 아님"
    }

    // MARK: 갱신

    /// 앱 시작 때 한 번 호출한다: 저장 환율은 이미 읽었고, 연결 상태 감시와 활성화 감시를 켠 뒤 갱신한다.
    func start() {
        guard !started else { return }
        started = true
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "ExchangeRateStore.path", qos: .utility))
        self.monitor = monitor
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh(.foreground) }
        }
        refresh(.launch)
    }

    private func pathChanged(online: Bool) {
        let wasOnline = isOnline
        isOnline = online
        // 연결이 돌아오면 최근에 실패했어도 바로 다시 시도한다(시작 직후 첫 보고는 시작 갱신이 처리).
        if online, wasOnline == false { refresh(.reconnect) }
    }

    /// 환율 갱신을 시작한다(기다리지 않음). 15분 안에 시도했으면 건너뛰고, 연결 복귀는 시도 기록과 무관하게 다시 시도한다.
    func refresh(_ reason: Reason) {
        if inflight != nil { return }
        if isOnline == false { return }
        if reason != .reconnect, let last = lastAttempt {
            let gap = (primary == nil && daily == nil) ? Self.noCacheRetry : Self.refreshInterval
            if Date().timeIntervalSince(last) < gap { return }
        }
        let started = Date()
        inflight = Task { [weak self] in
            let result = await Self.fetchLatest()
            guard let self else { return }
            self.finish(primary: result.0, daily: result.1, startedAt: started)
        }
    }

    /// 번역을 시작할 때 부른다(환율이 오래됐으면 뒤에서 갱신; 번역은 기다리지 않는다).
    func refreshIfNeeded() { refresh(.translationStart) }

    private func finish(primary newPrimary: Cache?, daily newDaily: Cache?, startedAt: Date) {
        inflight = nil
        let defaults = UserDefaults.standard
        var changed = false
        // 더 오래된 응답으로 이미 저장된 더 새로운 값을 덮어쓰지 않는다. 각 출처는 따로 저장한다.
        if let new = newPrimary {
            let older = primary?.sourceTime.flatMap { old in new.sourceTime.map { $0 < old } } ?? false
            if !older {
                primary = new
                if let data = try? JSONEncoder().encode(new) { defaults.set(data, forKey: Self.cacheKey) }
                changed = true
            }
        }
        if let new = newDaily {
            let older = daily?.sourceDate.flatMap { old in new.sourceDate.map { $0 < old } } ?? false
            if !older {
                daily = new
                if let data = try? JSONEncoder().encode(new) { defaults.set(data, forKey: Self.dailyKey) }
                changed = true
            }
        }
        let succeeded = newPrimary != nil || (primary == nil && newDaily != nil)
        lastAttempt = startedAt
        lastAttemptSucceeded = succeeded
        defaults.set(startedAt, forKey: Self.attemptKey)
        defaults.set(succeeded, forKey: Self.attemptOKKey)
        guard changed else { return } // 실패: 마지막 유효 환율은 그대로 둔다
        rebuildTable()
        NotificationCenter.default.post(name: .exchangeRatesDidUpdate, object: nil)
    }

    // MARK: 네트워크(주 스레드 밖)

    /// 주 응답과 일별 보조 스냅샷을 함께 받는다(주 응답이 성공해도 보조를 받는다; 노드마다 요청하지 않는다).
    private nonisolated static func fetchLatest() async -> (Cache?, Cache?) {
        async let main = fetchFirst([(primaryURL, 2, parsePrimary)])
        async let supplement = fetchFirst(fallbackURLs.map { ($0, 1, parseFawaz) })
        return await (main, supplement)
    }

    private nonisolated static func fetchFirst(_ endpoints: [(URL, Int, (Any, URL) -> Cache?)]) async -> Cache? {
        for (url, tries, parse) in endpoints {
            for attempt in 0..<tries {
                if Task.isCancelled { return nil }
                switch await fetchJSON(url) {
                case .success(let json):
                    if let cache = parse(json, url) { return cache }
                    break // 형식이 틀린 응답은 다시 받아도 같다
                case .failure(let retryable):
                    if retryable, attempt + 1 < tries { try? await Task.sleep(nanoseconds: 700_000_000); continue }
                }
                break
            }
        }
        return nil
    }

    private enum FetchOutcome { case success(Any), failure(retryable: Bool) }

    private nonisolated static func fetchJSON(_ url: URL) async -> FetchOutcome {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = endpointTimeout
        configuration.timeoutIntervalForResource = endpointTimeout + 2
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = endpointTimeout
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(retryable: true) }
            guard (200..<300).contains(http.statusCode) else { return .failure(retryable: http.statusCode >= 500) }
            guard data.count <= 2_000_000, let json = try? JSONSerialization.jsonObject(with: data) else { return .failure(retryable: false) }
            return .success(json)
        } catch {
            return .failure(retryable: true)
        }
    }

    // MARK: 검증·정규화

    /// 법정 통화(ISO 4217) 코드의 유한한 양수 환율만 남긴다. USD=1을 보장하고 KRW가 없으면 nil.
    nonisolated static func normalize(_ raw: [String: Double]) -> [String: Double]? {
        var rates: [String: Double] = [:]
        for (name, value) in raw {
            let code = name.uppercased()
            guard code.count == 3, CurrencyParser.fiat.contains(code), value.isFinite, value > 0 else { continue }
            rates[code] = value
        }
        let count = rates.count
        if rates["USD"] == nil { rates["USD"] = 1 }
        guard let krw = rates["KRW"], krw > 0, count >= 5 else { return nil }
        return rates
    }

    private nonisolated static func rateMap(_ any: Any?) -> [String: Double]? {
        guard let dictionary = any as? [String: Any] else { return nil }
        var result: [String: Double] = [:]
        for (key, value) in dictionary {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
            result[key] = number.doubleValue
        }
        return result
    }

    nonisolated static func krwTable(_ rates: [String: Double]) -> [String: Double] {
        guard let krw = rates["KRW"], krw > 0 else { return [:] }
        var table: [String: Double] = [:]
        for (code, rate) in rates where rate > 0 {
            let per = krw / rate
            if per.isFinite, per > 0 { table[code] = per }
        }
        return table
    }

    private nonisolated static func parseTime(_ any: Any?) -> Date? {
        if let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let value = number.doubleValue
            guard value.isFinite, value > 0 else { return nil }
            return Date(timeIntervalSince1970: value < 1e12 ? value : value / 1000)
        }
        guard let text = any as? String, !text.isEmpty else { return nil }
        if let value = Double(text) { return Date(timeIntervalSince1970: value < 1e12 ? value : value / 1000) }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fractional.date(from: text)
    }

    private nonisolated static func parsePrimary(_ json: Any, _ url: URL) -> Cache? {
        guard let object = json as? [String: Any], object["result"] as? String == "success",
              (object["base"] as? String)?.uppercased() == "USD",
              let raw = rateMap(object["rates"]), let rates = normalize(raw) else { return nil }
        // 제공사가 알려준 관측 시각은 우리가 받아 온 시각(fetchedAt)과 따로 둔다.
        let observed = parseTime(object["data_updated_at"]) ?? parseTime(object["effective_at"]) ?? parseTime(object["timestamp"])
        // 유효한 제공사 관측 시각이 없거나 24시간 넘게 미래이면 받아들이지 않는다(수신 시각을 시장 시각으로 쓰지 않는다).
        guard let observed, observed <= Date().addingTimeInterval(86_400) else { return nil }
        return Cache(provider: .exchangerateDev, rates: rates, sourceTime: observed, sourceDate: nil, fetchedAt: Date(),
                     stale: object["stale"] as? Bool == true)
    }

    private nonisolated static func parseFawaz(_ json: Any, _ url: URL) -> Cache? {
        guard let object = json as? [String: Any], let date = object["date"] as? String,
              date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let raw = rateMap(object["usd"]), let rates = normalize(raw) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        // 실제 달력 날짜이고 문자열이 그대로 왕복되어야 하며, 24시간 넘게 미래이면 거부한다.
        guard let parsed = formatter.date(from: date), formatter.string(from: parsed) == date,
              parsed <= Date().addingTimeInterval(86_400) else { return nil }
        return Cache(provider: .fawaz, rates: rates, sourceTime: parsed, sourceDate: date, fetchedAt: Date(), stale: false)
    }

    // MARK: 언어 단서

    nonisolated static func dominantLanguage(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        return recognizer.dominantLanguage?.rawValue
    }
}

// MARK: - SwiftUI 도우미

extension ExchangeRateStore {
    /// 번역문에서 외국 금액 바로 뒤에 작은 회색 "(약 N원)"을 붙인 문자열. 환율이 없거나 환산할 금액이 없으면 nil.
    /// original은 언어 단서(¥ 등)를 정하는 데만 쓴다(없으면 번역문으로 대신한다).
    func annotated(_ translated: String, original: String?) -> AttributedString? {
        guard hasRates, CurrencyParser.mightContainAmount(translated) else { return nil }
        let basis = original ?? translated
        let context = CurrencyContext(textLang: Self.dominantLanguage(of: basis), text: basis)
        let parts = CurrencyParser.segments(of: translated, context: context, krwPer: krwPer)
        guard parts.contains(where: \.isAnnotation) else { return nil }
        var result = AttributedString()
        for part in parts {
            var piece = AttributedString(part.isAnnotation ? " " + part.text : part.text)
            if part.isAnnotation {
                piece.font = .footnote
                piece.foregroundColor = Color.secondary
            }
            result += piece
        }
        return result
    }
}

/// 메인 창 아래의 작은 환율 출처 줄(가격 주석과 별도). 받은 적이 없으면 안내 문구, 기본 제공사 데이터면 출처 링크를 보인다.
struct ExchangeRateStatusLine: View {
    private let store = ExchangeRateStore.shared

    var body: some View {
        HStack(spacing: 8) {
            Text(store.statusText)
                .help(store.detailText)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            // 제공사 약관상 출처 표기: 좁은 창에서도 숨기거나 잘라 내지 않는다(상태 문구가 먼저 줄어든다).
            if store.attributionVisible {
                Link(ExchangeRateStore.attributionText, destination: ExchangeRateStore.attributionURL)
                    .font(.system(size: 10))
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
        .lineLimit(1)
    }
}
