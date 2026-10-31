import CoreGraphics
import Foundation
import ImageIO
import Translation
import OSLog

// 브라우저 번역 엔진(앱 본체와 Safari 확장 공용). 확장이 보낸 요청을 검증하고, 페이지 글자 조각과
// 보이는 탭 캡처 중 이미지 영역만 잘라 OCR한 글자를 Mac 기본 번역(기기 내)으로 번역해 텍스트만 돌려준다.
// - 브라우저 번역은 앱의 번역 방식 설정(외부 AI 포함)을 읽거나 바꾸지 않는다. 기본은 Mac 기본 번역이며, 확장에서 사용자가
//   웹 번역 엔진(DeepL·Google·Papago)을 따로 고르고 동의한 요청만 앱이 연결한 외부 번역기(external)로 넘긴다(Safari 확장에는 없음).
// - 요청·응답 내용과 이미지는 메모리에서만 쓰고 디스크에 저장하거나 기록하지 않는다.
// - 요청 ID는 연결(scope)마다 따로 관리해 한 브라우저의 취소가 다른 브라우저 요청을 건드리지 않는다.

enum BrowserEngineError: Error {
    case badRequest(String)
    case disabled
    case busy
    case imageTooLarge
    case languageNotInstalled(String)
    case unsupportedPair(String)
    case requiresNewerMacOS
    case translationFailed(String)
    case externalUnavailable
    case externalBlocked(String)
    /// Apple Intelligence 다듬기 실패(고정 사유 코드만, 내용·시스템 오류 문구 없음). 확장은 기존 번역을 그대로 둔다.
    case refineFailed(AppleTranslationRefiner.Failure)

    var code: String {
        switch self {
        case .badRequest: return "bad_request"
        case .disabled: return "app_disabled"
        case .busy: return "busy"
        case .imageTooLarge: return "image_too_large"
        case .languageNotInstalled: return "language_not_installed"
        case .unsupportedPair: return "unsupported_language"
        case .requiresNewerMacOS: return "requires_macos26"
        case .translationFailed: return "translation_failed"
        case .externalUnavailable: return "external_unavailable"
        case .externalBlocked: return "external_consent_required"
        case .refineFailed(let failure): return "refine_\(failure.rawValue)"
        }
    }

    var message: String {
        switch self {
        case .badRequest(let reason): return "잘못된 요청입니다(\(reason))."
        case .disabled: return "HTT 메뉴 막대 › '브라우저 번역…'에서 '브라우저 확장 연결 허용'을 켜 주세요."
        case .busy: return "처리 중인 요청이 많습니다. 잠시 뒤 다시 시도하세요."
        case .imageTooLarge: return "캡처 이미지가 너무 큽니다. 브라우저 창을 줄인 뒤 다시 시도하세요."
        case .languageNotInstalled(let pair):
            return "번역 언어 팩(\(pair))이 아직 없습니다. 시스템 설정 › 일반 › 언어 및 지역 › 번역 언어에서 내려받은 뒤 다시 번역하세요."
        case .unsupportedPair(let pair): return "Mac 기본 번역이 지원하지 않는 언어 조합입니다(\(pair))."
        case .requiresNewerMacOS: return "Safari 번역에는 macOS 26 이상이 필요합니다. Chrome·Whale 확장을 사용하세요."
        case .translationFailed(let reason): return "번역 실패: \(reason)"
        case .externalUnavailable:
            return "이 연결에서는 웹 번역(DeepL·Google·Papago)을 쓸 수 없습니다. Safari는 Mac 기본 번역만 지원합니다. 확장의 번역 엔진을 Mac 기본 번역으로 바꾸세요."
        case .externalBlocked(let reason): return reason
        case .refineFailed(let failure): return "Apple Intelligence 다듬기를 적용하지 못했습니다(\(failure.rawValue)). 기존 번역을 유지합니다."
        }
    }
}

/// 언어 하나(source) → target 번역. 결과는 입력과 같은 개수이며, 받지 못한 항목은 nil이다.
protocol BrowserTextTranslating: AnyObject, Sendable {
    func supportedLanguageIDs() async -> [String]
    func translate(_ texts: [String], source: String, target: String) async throws -> [String?]
    /// partial: 항목이 하나씩 끝나는 대로 (입력 안 위치, 번역문)을 알린다. 전체 결과 배열은 끝에 그대로 돌려준다.
    /// 부분 전달을 지원하지 않는 번역기는 알리지 않는다(최종 배열이 전부다).
    func translate(_ texts: [String], source: String, target: String, partial: BrowserPartialHandler?) async throws -> [String?]
}

extension BrowserTextTranslating {
    func translate(_ texts: [String], source: String, target: String, partial: BrowserPartialHandler?) async throws -> [String?] {
        try await translate(texts, source: source, target: target)
    }
}

/// 끝난 항목의 (입력 안 위치, 번역문). 번역문은 확장이 화면에 바로 쓸 값이며 로그에는 남기지 않는다.
typealias BrowserPartialHandler = @Sendable ([(index: Int, text: String)]) -> Void

/// 브라우저 "언어팩" 버튼: 번역 언어 내려받기는 시스템 설정(일반 › 언어 및 지역 › 번역 언어)에서 모든 앱이 공유한다.
/// 번역 언어 하위 화면의 공식 딥링크는 확인되지 않아 만들지 않고, 언어 및 지역 창만 연다.
enum BrowserLanguageSettings {
    static let regionURL = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!
    static let guidance = "시스템 설정 › 일반 › 언어 및 지역을 열었습니다. 아래쪽 '번역 언어'를 눌러 언어를 내려받으세요(받은 언어는 다른 앱과 공유됩니다)."
    static let failure = "시스템 설정을 열지 못했습니다. 시스템 설정 › 일반 › 언어 및 지역 › 번역 언어를 직접 열어 주세요."
}

/// 요청 하나의 중간 진행(확장이 요청에 progress: true를 실었을 때만 같은 id의 type "progress" 프레임으로 보낸다).
/// 단계 이름과 개수(정수)만 담고 원문·번역문·이미지는 담지 않는다.
struct BrowserProgress: Sendable {
    let phase: String
    var step: String? = nil
    var counts: [String: Int] = [:]
    /// phase "partial"일 때만: 요청 texts 안 위치와 번역문(끝난 항목만)
    var items: [(index: Int, text: String)] = []
    /// phase "partial"일 때만: 번역과 복원 조각이 모두 준비된 이미지 문단들(이미지 키별 JSON 배열). 외부 엔진은 쓰지 않는다.
    var images: Data?
}

typealias BrowserProgressHandler = @Sendable (BrowserProgress) -> Void

/// 웹 번역 엔진(앱 본체 전용). 항목마다 하나씩 번역하며, 결과는 입력과 같은 개수이고 받지 못한 항목은 nil이다.
/// 실행을 멈춰야 하는 오류는 그때까지 받은 결과와 함께 BrowserExternalFailure로 알린다.
protocol BrowserExternalTranslating: AnyObject, Sendable {
    var engineIDs: [String] { get }
    /// 지금 보낼 수 없으면(앱 쪽 동의 없음 등) 사용자에게 보여줄 이유
    func unavailableReason(engine: String) async -> String?
    /// 선택한 서비스의 빈 화면만 준비한다. 실제 원문 전송은 translate에서만 한다.
    func prepare(source: String, target: String, engine: String) async
    /// progress: 묶음 번호·묶음 수·묶음 항목 수·입력 글자 수와 단계(opening·input·waiting·challenge)만 알린다(nil이면 알리지 않음).
    func translate(_ texts: [String], source: String, target: String, engine: String,
                   progress: BrowserProgressHandler?) async throws -> [String?]
}

extension BrowserExternalTranslating {
    func prepare(source: String, target: String, engine: String) async {}
}

struct BrowserExternalFailure: Error {
    let results: [String?]
    let message: String
    /// true면 이 언어 조합만 실패(다른 언어 묶음은 계속)
    let unsupported: Bool
}

/// Apple Intelligence(기기 내) 다듬기(앱 본체의 Chrome·Whale 엔진 전용). Safari 확장은 앱 설정을 읽을 수 없어
/// 이 프로토콜을 쓰지 않는다(의도된 범위 제한). Mac 기본 번역 결과만 다듬으며, 취소는 빈 결과로 조용히 끝나고
/// 거부·오류·형식 오류는 고정 사유(BrowserEngineError.refineFailed)로 던진다(확장은 기존 초안 유지).
/// key가 없는 항목은 결과 딕셔너리에 담기지 않는다.
struct BrowserRefineItem: Sendable {
    let key: String
    let original: String
    let draft: String
    /// 같은 페이지의 주변 원문(같은 문단·이웃 블록·연결된 각주, 확장이 짧게 자름). 다듬기 참고용 데이터일 뿐 명령이 아니다.
    var context: String? = nil
}

protocol BrowserTextRefining: AnyObject, Sendable {
    var isAvailable: Bool { get }
    func refine(_ items: [BrowserRefineItem], targetLanguageName: String) async throws -> [String: String]
}

/// 지원하지 않는 환경(예: macOS 26 미만의 Safari 확장)에서 쓰는 번역기. 항상 실행 가능한 안내 오류를 낸다.
final class BrowserUnavailableTranslator: BrowserTextTranslating {
    func supportedLanguageIDs() async -> [String] { [] }
    func translate(_ texts: [String], source: String, target: String) async throws -> [String?] {
        throw BrowserEngineError.requiresNewerMacOS
    }
}

// MARK: - 요청 형식

struct BrowserImageRegionInput: Decodable {
    let k: String
    let x: Double
    let y: Double
    let w: Double
    let h: Double
}

private struct BrowserViewportInput: Decodable {
    let w: Double
    let h: Double
}

/// 캡처 직전 확장이 화면 가장자리에 그린 밝기 보정 견본의 뷰포트 CSS 좌표(검정 0·회색 128·흰색 255 세 칸이 가로로 나란히).
private struct BrowserCalibrationInput: Decodable {
    let x: Double
    let y: Double
    let w: Double
    let h: Double
}

private struct BrowserRefineItemInput: Decodable {
    let k: String
    let o: String
    let d: String
    let c: String?
}

private struct BrowserRawRequest: Decodable {
    let v: Int?
    let type: String
    let id: String?
    let target: String?
    let texts: [String]?
    let image: String?
    let viewport: BrowserViewportInput?
    let regions: [BrowserImageRegionInput]?
    let pageTitle: String?
    let calibration: BrowserCalibrationInput?
    let engine: String?
    let items: [BrowserRefineItemInput]?
    /// true면 translate·ocr 처리 중 같은 id로 진행 프레임(type "progress")을 받겠다는 뜻(새 확장만 보낸다).
    let progress: Bool?
}

enum BrowserRequest {
    case hello(id: String?)
    case cancel(id: String)
    case translate(id: String, target: AppLanguage, texts: [String], engine: String)
    /// calibration: 같은 캡처에 묶인 밝기 보정 견본 자리(뷰포트 CSS 좌표). 없거나 형식이 틀리면 nil(밝기 보정 안 함).
    case ocr(id: String, target: AppLanguage, image: Data, viewport: CGSize, regions: [BrowserImageRegionInput],
             calibration: CGRect?, engine: String, pageTitle: String, companionTexts: [String])
    /// 이미 화면에 그려진 Mac 기본 번역 초안을 다듬는 작은 후속 요청(앱 본체의 Chrome·Whale 전용).
    case refine(id: String, target: AppLanguage, items: [BrowserRefineItem])
    /// 팝업의 "언어팩" 버튼: 실제 번역 언어 팩 다운로드 화면을 연다(언어/지역 설정이 아님).
    case openLanguagePack(id: String)

    static let maxTexts = 150
    static let maxTextLength = 5000
    static let maxTotalCharacters = 40_000
    static let maxRegions = 16
    static let maxImagePixels = 60_000_000
    static let maxImageSide = 12_000
    /// 밝기 보정 견본 크기 범위(CSS px). 확장은 18px 칸 세 개(54×18)를 그린다.
    static let calibrationWidth = 48.0...96.0
    static let calibrationHeight = 16.0...32.0
    /// 기본 엔진(Mac 기본 번역). 확장이 engine을 보내지 않으면(구버전) 이 값이다.
    static let localEngine = "apple"
    static let externalEngines = ["deepl", "google", "papago"]
    /// 웹 번역 엔진은 항목마다 차례로 처리하므로 한 요청을 작게 받는다.
    static let maxExternalTexts = 12
    /// DeepL은 WebTranslatorBrowserBridge가 입력 한도(1400 UTF-16, 식별자 포함) 안에서 여러 항목을 묶어 보내므로(DeepLBatcher)
    /// 항목 수만 확장의 한 번 수집 상한(MAX_EXTERNAL_UNITS)까지 받는다. 전체 글자 상한은 같다.
    static let maxDeepLTexts = 120
    static let maxExternalCharacters = 15_000
    /// Apple Intelligence 후속 다듬기 요청(이미 그려진 결과만 소소하게 고침, 큰 묶음이 아니다).
    static let maxRefineItems = 16 // 이미지·일반 글자의 기존 두 묶음. 전체 글자·문맥 상한은 유지한다.
    static let maxRefineItemCharacters = 700
    static let maxRefineCharacters = 4000
    /// 다듬기 항목별 주변 원문(선택) 상한과 요청 전체 상한.
    static let maxRefineContextCharacters = 300
    static let maxRefineContextTotal = 1200

    /// progress: 요청이 진행 프레임을 받겠다고 했는지(구버전 확장은 보내지 않아 false — 진행 프레임을 결과로 오인하지 않게).
    static func parse(_ data: Data) throws -> (request: BrowserRequest, progress: Bool) {
        let raw: BrowserRawRequest
        do {
            raw = try JSONDecoder().decode(BrowserRawRequest.self, from: data)
        } catch {
            throw BrowserEngineError.badRequest("형식")
        }
        return (try request(from: raw), raw.progress == true)
    }

    private static func request(from raw: BrowserRawRequest) throws -> BrowserRequest {
        guard raw.v == nil || raw.v == 1 else { throw BrowserEngineError.badRequest("버전") }
        switch raw.type {
        case "hello":
            return .hello(id: raw.id.flatMap { validKey($0) ? $0 : nil })
        case "cancel":
            return .cancel(id: try validID(raw.id))
        case "translate":
            let id = try validID(raw.id)
            let target = try validTarget(raw.target)
            let engine = try validEngine(raw.engine)
            let external = engine != localEngine
            let maxCount = engine == "deepl" ? maxDeepLTexts : (external ? maxExternalTexts : maxTexts)
            guard let texts = raw.texts, !texts.isEmpty, texts.count <= maxCount else {
                throw BrowserEngineError.badRequest("항목 수")
            }
            var total = 0
            for text in texts {
                guard text.count <= maxTextLength else { throw BrowserEngineError.badRequest("항목 길이") }
                total += text.count
            }
            guard total <= (external ? maxExternalCharacters : maxTotalCharacters) else { throw BrowserEngineError.badRequest("전체 길이") }
            return .translate(id: id, target: target, texts: texts, engine: engine)
        case "ocr":
            let id = try validID(raw.id)
            let target = try validTarget(raw.target)
            guard let viewport = raw.viewport, viewport.w.isFinite, viewport.h.isFinite,
                  (1...20_000).contains(viewport.w), (1...20_000).contains(viewport.h) else {
                throw BrowserEngineError.badRequest("화면 크기")
            }
            guard let regions = raw.regions, !regions.isEmpty, regions.count <= maxRegions else {
                throw BrowserEngineError.badRequest("이미지 영역 수")
            }
            for region in regions {
                guard validKey(region.k),
                      [region.x, region.y, region.w, region.h].allSatisfy({ $0.isFinite && abs($0) <= 100_000 }),
                      region.w >= 1, region.h >= 1 else { throw BrowserEngineError.badRequest("이미지 영역") }
            }
            guard let image = raw.image else { throw BrowserEngineError.badRequest("이미지") }
            let prefixes = ["data:image/jpeg;base64,", "data:image/png;base64,"]
            guard let prefix = prefixes.first(where: { image.hasPrefix($0) }),
                  let bytes = Data(base64Encoded: String(image.dropFirst(prefix.count))) else {
                throw BrowserEngineError.badRequest("이미지 형식")
            }
            // 견본 자리는 선택값이다. 범위를 벗어나면 오류로 막지 않고 버려(nil) 밝기를 짐작으로 고치지 않게 한다.
            let calibration = raw.calibration.flatMap { c -> CGRect? in
                guard [c.x, c.y, c.w, c.h].allSatisfy(\.isFinite), c.x >= 0, c.y >= 0,
                      calibrationWidth.contains(c.w), calibrationHeight.contains(c.h),
                      c.x + c.w <= viewport.w, c.y + c.h <= viewport.h else { return nil }
                return CGRect(x: c.x, y: c.y, width: c.w, height: c.h)
            }
            let engine = try validEngine(raw.engine)
            let companionTexts = raw.texts ?? []
            let maxCount = engine == "deepl" ? maxDeepLTexts : maxExternalTexts
            guard companionTexts.isEmpty || engine != localEngine,
                  companionTexts.count <= maxCount,
                  companionTexts.allSatisfy({ $0.utf16.count <= maxTextLength }),
                  companionTexts.reduce(0, { $0 + $1.utf16.count }) <= maxExternalCharacters else {
                throw BrowserEngineError.badRequest("동반 글자")
            }
            return .ocr(id: id, target: target, image: bytes, viewport: CGSize(width: viewport.w, height: viewport.h), regions: regions,
                        calibration: calibration, engine: engine, pageTitle: String((raw.pageTitle ?? "").prefix(300)), companionTexts: companionTexts)
        case "refine":
            let id = try validID(raw.id)
            let target = try validTarget(raw.target)
            guard let rawItems = raw.items, !rawItems.isEmpty, rawItems.count <= maxRefineItems else {
                throw BrowserEngineError.badRequest("다듬기 항목 수")
            }
            var total = 0
            var contextTotal = 0
            var items: [BrowserRefineItem] = []
            for item in rawItems {
                guard validKey(item.k), item.o.count <= maxRefineItemCharacters, item.d.count <= maxRefineItemCharacters,
                      (item.c?.count ?? 0) <= maxRefineContextCharacters else {
                    throw BrowserEngineError.badRequest("다듬기 항목")
                }
                total += item.o.count + item.d.count
                contextTotal += item.c?.count ?? 0
                let context = item.c.flatMap { $0.isEmpty ? nil : $0 }
                items.append(BrowserRefineItem(key: item.k, original: item.o, draft: item.d, context: context))
            }
            guard total <= maxRefineCharacters, contextTotal <= maxRefineContextTotal else {
                throw BrowserEngineError.badRequest("다듬기 전체 길이")
            }
            return .refine(id: id, target: target, items: items)
        case "openLanguagePack":
            return .openLanguagePack(id: try validID(raw.id))
        default:
            throw BrowserEngineError.badRequest("종류")
        }
    }

    private static func validID(_ id: String?) throws -> String {
        guard let id, validKey(id) else { throw BrowserEngineError.badRequest("요청 ID") }
        return id
    }

    private static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 64
            && key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_:.".unicodeScalars.contains($0) }
            && key.unicodeScalars.allSatisfy(\.isASCII)
    }

    private static func validEngine(_ engine: String?) throws -> String {
        guard let engine else { return localEngine }
        guard engine == localEngine || externalEngines.contains(engine) else { throw BrowserEngineError.badRequest("번역 엔진") }
        return engine
    }

    private static func validTarget(_ target: String?) throws -> AppLanguage {
        guard let target, let language = AppLanguage(rawValue: target) else { throw BrowserEngineError.badRequest("번역 언어") }
        return language
    }
}

// MARK: - 이미지 부분 번역 버퍼

/// 문단마다 "번역문"과 "복원 조각·글자 상자(그림 단위 분석 결과)"가 모두 준비되는 즉시 한 번씩 내보낸다. 어느 쪽이 먼저 오든
/// 다른 쪽을 기다리는 것은 그 문단뿐이고, 다른 문단·그림의 분석이나 번역 묶음 전체를 기다리지 않는다.
/// 같은 번역문이 다시 오면(재시도·같은 문장 반복) 다시 내보내지 않고, 번역문이 바뀐 경우에만 같은 id로 갱신해 내보낸다.
private final class ImageStreamBuffer: @unchecked Sendable {
    struct Entry {
        let index: Int
        let key: String
        let dict: [String: Any]
        let source: String
    }

    private let lock = NSLock()
    private var drafts: [Int: String] = [:]
    private var entries: [Int: [Entry]] = [:]
    private var sent: [Int: String] = [:]
    private let deliver: ([(key: String, dict: [String: Any])]) -> Void
    private let finalText: (String, String) -> String

    init(finalText: @escaping (String, String) -> String, deliver: @escaping ([(key: String, dict: [String: Any])]) -> Void) {
        self.finalText = finalText
        self.deliver = deliver
    }

    func receive(_ items: [(index: Int, text: String)]) {
        lock.lock()
        var indexes: [Int] = []
        for item in items {
            let draft = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !draft.isEmpty else { continue }
            drafts[item.index] = draft
            indexes.append(item.index)
        }
        let out = collect(indexes)
        lock.unlock()
        if !out.isEmpty { deliver(out) }
    }

    func addReady(_ list: [Entry]) {
        lock.lock()
        var indexes: [Int] = []
        for entry in list {
            entries[entry.index, default: []].append(entry)
            indexes.append(entry.index)
        }
        let out = collect(indexes)
        lock.unlock()
        if !out.isEmpty { deliver(out) }
    }

    /// lock을 잡은 채 호출한다. 번역문과 준비된 항목이 모두 있고 마지막으로 보낸 번역문과 다른 문단만 고른다.
    private func collect(_ indexes: [Int]) -> [(key: String, dict: [String: Any])] {
        var out: [(key: String, dict: [String: Any])] = []
        var seen = Set<Int>()
        for index in indexes where seen.insert(index).inserted {
            guard let draft = drafts[index], let list = entries[index], sent[index] != draft else { continue }
            sent[index] = draft
            for entry in list {
                var dict = entry.dict
                dict["t"] = finalText(entry.source, draft)
                out.append((entry.key, dict))
            }
        }
        return out
    }
}

// MARK: - 엔진

actor BrowserEngine {
    static let engineID = "apple-local"
    static let engineTitle = "Mac 기본 번역(기기 내)"
    /// 연결 하나에서 동시에 처리하는 요청 수 상한
    private static let maxTasksPerScope = 6
    private static let batchSize = 40
    private static let maxOCRItems = 300
    /// 웹 번역 엔진으로 보내는 이미지 글자 상한(요청 하나). 넘는 조각은 번역하지 않는다.
    private static let maxExternalOCRItems = 24
    /// recognizeAndTranslate 응답 하나에서 내보내는 글자 상자(g) 총 개수 상한(항목당 128개와 별도).
    /// maxOCRItems(최대 300) × 항목당 최대 128개면 38,400개까지 가능해 메타데이터만으로 1MB 프레임 상한을
    /// 넘길 수 있으므로, 전체 응답 크기를 데이터 기준으로 묶어 둔다.
    private static let maxOutgoingGlyphBoxes = 8192
    /// 응답 하나에서 내보내는 배경 복원 조각(base64 PNG) 총 글자 수 상한. 실제로는 조각을 뺀 응답 크기를 잰 뒤 1MB
    /// 프레임 상한까지 남은 만큼만 싣는다. 넘는 항목은 조각만 생략하고 확장이 글자 상자를 배경색으로 가린다.
    private static let maxOutgoingRestorationCharacters = 900_000

    private let translator: BrowserTextTranslating
    private let external: BrowserExternalTranslating?
    /// Apple Intelligence 다듬기(앱 본체의 Chrome·Whale 엔진에서만 nil이 아니다. Safari는 항상 nil).
    private let refiner: BrowserTextRefining?
    private let isEnabled: @Sendable () async -> Bool
    /// "언어팩" 버튼 요청 처리(언어/지역 설정이 아니라 실제 다운로드 화면을 연다). 호출부(앱 본체·Safari 확장)마다
    /// 보여줄 수 있는 화면이 달라 엔진이 직접 AppKit 창을 열지 않고 주입받는다. 실제 다운로드 화면을 직접 열지
    /// 못하는 호출부(Safari 확장)는 무엇을 했고 사용자가 다음에 뭘 해야 하는지 설명하는 문구를 돌려준다(nil이면
    /// 화면을 직접 열어 추가 설명이 필요 없다는 뜻).
    private let openLanguagePack: @Sendable () async -> String?
    private var tasks: [String: Task<Data, Never>] = [:]
    private var supportedIDs: [String]?

    init(translator: BrowserTextTranslating, external: BrowserExternalTranslating? = nil,
         refiner: BrowserTextRefining? = nil, isEnabled: @escaping @Sendable () async -> Bool,
         openLanguagePack: @escaping @Sendable () async -> String?) {
        self.translator = translator
        self.external = external
        self.refiner = refiner
        self.isEnabled = isEnabled
        self.openLanguagePack = openLanguagePack
    }

    /// 요청 한 개를 처리해 응답 JSON을 돌려준다. 응답은 항상 Chrome 상한(1MB) 이하다.
    /// emit: 같은 연결에 중간 진행 프레임을 쓰는 함수(요청이 progress: true일 때만 쓴다). 진행 프레임은 같은 id·type
    /// "progress"이며 단계 이름과 개수만 담는다. 최종 응답보다 먼저 같은 직렬 쓰기 순서로 나간다.
    func handle(_ data: Data, scope: String, emit: (@Sendable (Data) -> Void)? = nil) async -> Data {
        let request: BrowserRequest
        let wantsProgress: Bool
        do {
            (request, wantsProgress) = try BrowserRequest.parse(data)
        } catch {
            return Self.encodeError(error, id: nil)
        }

        switch request {
        case .hello(let id):
            var response: [String: Any] = [
                "type": "hello", "ok": true, "engine": Self.engineID, "engineTitle": Self.engineTitle,
                "enabled": await isEnabled(),
                "externalEngines": external?.engineIDs ?? [],
                "aiRefine": refiner?.isAvailable ?? false,
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            ]
            if let id { response["id"] = id }
            return Self.encode(response)
        case .cancel(let id):
            tasks["\(scope)|\(id)"]?.cancel()
            return Self.encode(["type": "ack", "ok": true, "id": id])
        case .openLanguagePack(let id):
            let message = await openLanguagePack()
            var response: [String: Any] = ["type": "languagePackOpened", "ok": true, "id": id]
            if let message { response["message"] = message }
            return Self.encode(response)
        case .translate(let id, _, _, _), .ocr(let id, _, _, _, _, _, _, _, _), .refine(let id, _, _):
            guard await isEnabled() else { return Self.encodeError(BrowserEngineError.disabled, id: id) }
            let key = "\(scope)|\(id)"
            tasks[key]?.cancel()
            guard tasks.keys.filter({ $0.hasPrefix("\(scope)|") }).count < Self.maxTasksPerScope else {
                return Self.encodeError(BrowserEngineError.busy, id: id)
            }
            var progress: BrowserProgressHandler?
            if wantsProgress, let emit {
                progress = { update in
                    guard !Task.isCancelled else { return }
                    var frame: [String: Any] = ["type": "progress", "id": id, "phase": update.phase, "counts": update.counts]
                    if let step = update.step { frame["step"] = step }
                    if !update.items.isEmpty { frame["items"] = update.items.map { ["i": $0.index, "t": $0.text] as [String: Any] } }
                    if let images = update.images, let object = try? JSONSerialization.jsonObject(with: images) { frame["images"] = object }
                    // 부분 프레임이 한 프레임 상한을 넘으면 건너뛴다(최종 응답이 전부를 담는다).
                    if let data = try? JSONSerialization.data(withJSONObject: frame), data.count <= BrowserBridge.maxOutgoingFrame { emit(data) }
                }
            }
            let task = Task { [progress] in await self.run(request, id: id, progress: progress) }
            tasks[key] = task
            let result = await task.value
            if tasks[key] == task { tasks[key] = nil }
            return result
        }
    }

    /// 연결이 끊기면 그 연결의 요청만 모두 취소한다.
    func cancelAll(scope: String) {
        for (key, task) in tasks where key.hasPrefix("\(scope)|") {
            task.cancel()
            tasks[key] = nil
        }
    }

    private func run(_ request: BrowserRequest, id: String, progress: BrowserProgressHandler? = nil) async -> Data {
        do {
            let response: [String: Any]
            switch request {
            case .translate(_, let target, let texts, let engine):
                let started = ContinuousClock.now
                let (results, missing, langs, warning) = try await translateTexts(texts, target: target, engine: engine, progress: progress)
                let elapsed = (ContinuousClock.now - started).components
                var object: [String: Any] = ["type": "result", "ok": true, "id": id,
                            "timing": ["translate": Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)],
                            "texts": results.map { $0.map { $0 as Any } ?? NSNull() }, "missing": missing,
                            "langs": langs.map { $0.map { $0 as Any } ?? NSNull() }, "aiRefine": engine == BrowserRequest.localEngine && (refiner?.isAvailable ?? false)]
                if let warning { object["warning"] = warning }
                response = object
            case .ocr(_, let target, let image, let viewport, let regions, let calibration, let engine, let pageTitle, let companionTexts):
                let (images, missing, warning, measured, timing, companionResults) = try await recognizeAndTranslate(
                    image, viewport: viewport, regions: regions, calibration: calibration, target: target, engine: engine,
                    pageTitle: pageTitle, companionTexts: companionTexts, progress: progress)
                var object: [String: Any] = ["type": "ocrResult", "ok": true, "id": id, "images": images, "missing": missing,
                            "aiRefine": engine == BrowserRequest.localEngine && (refiner?.isAvailable ?? false),
                            "calibration": measured.dictionary, "timing": timing,
                            "texts": companionResults.map { $0.map { $0 as Any } ?? NSNull() }]
                if let warning { object["warning"] = warning }
                response = object
            case .refine(_, let target, let items):
                let refined = try await refineItems(items, target: target)
                // meta: 이번 요청이 실제로 돌았는지(fresh), 지난 결과를 재사용했는지(hit)를 개수로만 알린다(옛 확장은 무시).
                response = ["type": "refineResult", "ok": true, "id": id,
                            "items": refined.items.map { ["k": $0.key, "t": $0.value] },
                            "meta": ["sel": refined.selected, "hit": refined.cacheHit, "fresh": refined.fresh,
                                     "changed": refined.items.count, "ms": refined.ms, "out": refined.outcome]]
            default:
                throw BrowserEngineError.badRequest("종류")
            }
            try Task.checkCancellation()
            let data = Self.encode(response)
            guard data.count <= BrowserBridge.maxOutgoingFrame else {
                return BrowserBridge.errorFrame(code: "response_too_large", message: "번역 결과가 너무 큽니다. 다시 시도하면 더 작은 묶음으로 나눕니다.", id: id)
            }
            return data
        } catch is CancellationError {
            return Self.encode(["type": "cancelled", "ok": false, "code": "cancelled", "id": id])
        } catch {
            if Task.isCancelled { return Self.encode(["type": "cancelled", "ok": false, "code": "cancelled", "id": id]) }
            return Self.encodeError(error, id: id)
        }
    }

    // MARK: 텍스트 번역 (언어별 묶음)

    /// 조각마다 언어를 판별해 같은 언어끼리 그 언어를 명시한 세션으로 번역한다(원문 언어가 nil인 세션을 쓰지 않아
    /// 언어 선택 창이 뜨지 않는다). 글자가 없거나 이미 번역 언어이거나 판별·지원되지 않는 조각은 nil(원문 유지).
    /// 세 번째 결과는 조각마다 실제로 쓴 판별 언어(글자 없음은 nil, 판별 못 하면 "unknown")로, 번역 성공 여부와 무관하게
    /// 확장이 인식 통계를 보여주는 데 쓴다. 네 번째 결과는 웹 번역 엔진이 도중에 멈췄을 때의 안내(받은 결과는 유지)다.
    /// 웹 번역 엔진도 같은 언어 판별을 거쳐, 판별한 언어를 원문 언어로 지정해 보낸다(판별 못 한 조각은 보내지 않는다).
    /// progress: Mac 기본 번역은 시작할 때 보낼 조각 수를, 웹 번역 엔진은 언어 묶음마다 전체·이미 보낸 항목 수와 글자 수에
    /// 묶음별 진행(BrowserExternalTranslating)을 더해 알린다. 개수만 담는다.
    private func translateTexts(_ texts: [String], target: AppLanguage, engine: String,
                                progress: BrowserProgressHandler? = nil,
                                repairResidue: Bool = false) async throws -> ([String?], [String], [String?], String?) {
        let isExternal = engine != BrowserRequest.localEngine
        if isExternal {
            guard let external, external.engineIDs.contains(engine) else { throw BrowserEngineError.externalUnavailable }
            if let reason = await external.unavailableReason(engine: engine) { throw BrowserEngineError.externalBlocked(reason) }
        }
        let classified = texts.map { LanguageDetection.classify($0) }
        let detected = LanguageDetection.resolveAmbiguous(classified)
        let langs: [String?] = detected.map { result in
            switch result {
            case .language(let key): return key
            case .unknown: return "unknown"
            case .noLetters, .ambiguous: return nil
            }
        }
        if !isExternal && (supportedIDs == nil || supportedIDs?.isEmpty == true) {
            supportedIDs = await translator.supportedLanguageIDs()
        }
        var order: [String] = []
        var groups: [String: [Int]] = [:]
        for (index, result) in detected.enumerated() {
            guard case .language(let key) = result,
                  !LanguageDetection.isSameLanguage(key, target.rawValue), isExternal || isSupported(key) else { continue }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(index)
        }

        var results = [String?](repeating: nil, count: texts.count)
        var missing: [String] = []
        var firstError: Error?
        var warning: String?
        let sendable = order.flatMap { groups[$0] ?? [] }
        let totalItems = sendable.count
        let totalChars = sendable.reduce(0) { $0 + texts[$1].utf16.count }
        var doneItems = 0
        let diagnosticRequestID = OnboardDiagnostics.newRequestID()
        var diagnosticBatch = 0
        let diagnosticBatches = order.reduce(0) { $0 + (((groups[$1] ?? []).count + Self.batchSize - 1) / Self.batchSize) }
        if !isExternal {
            OnboardDiagnostics.record("request", [
                "request": diagnosticRequestID, "engine": engine, "target": target.rawValue, "items": totalItems,
                "utf16": totalChars, "batches": diagnosticBatches, "batchSize": Self.batchSize, "inputItems": texts.count,
                "languageGroups": order.map { "\($0):\((groups[$0] ?? []).count)" }])
        }
        if !isExternal, totalItems > 0 {
            progress?(BrowserProgress(phase: "translating", counts: ["totalItems": totalItems, "totalChars": totalChars]))
        }
        groups: for key in order {
            let indices = groups[key] ?? []
            var start = 0
            groupLoop: while start < indices.count {
                try Task.checkCancellation()
                let chunk = Array(indices[start..<min(start + Self.batchSize, indices.count)])
                start += Self.batchSize
                do {
                    var output: [String?]
                    if isExternal, let external {
                        let done = doneItems
                        let relay: BrowserProgressHandler? = progress.map { progress in
                            { update in
                                var counts = update.counts
                                counts["totalItems"] = totalItems
                                counts["totalChars"] = totalChars
                                counts["doneItems"] = done
                                progress(BrowserProgress(phase: update.phase, step: update.step, counts: counts))
                            }
                        }
                        output = try await external.translate(chunk.map { texts[$0] }, source: key, target: target.rawValue, engine: engine,
                                                              progress: relay)
                        doneItems += chunk.count
                    } else {
                        let batchTexts = chunk.map { texts[$0] }
                        // 끝나는 항목을 요청 전체 위치로 바꿔 바로 알린다(진행 프레임을 받겠다고 한 요청만). 최종 배열은 그대로 쓴다.
                        let sourceTexts = texts
                        let partial: BrowserPartialHandler? = progress.map { progress in
                            { items in
                                let mapped: [(index: Int, text: String)] = items.compactMap { item in
                                    guard chunk.indices.contains(item.index) else { return nil }
                                    let index = chunk[item.index]
                                    let text = target == .korean ? BrowserMenuTranslation.korean(sourceTexts[index]) ?? item.text : item.text
                                    return (index, text)
                                }
                                if !mapped.isEmpty { progress(BrowserProgress(phase: "partial", items: mapped)) }
                            }
                        }
                        output = try await OnboardDiagnostics.$context.withValue(
                            OnboardDiagnostics.Context(requestID: diagnosticRequestID, batch: diagnosticBatch, batches: diagnosticBatches)) {
                            try await translator.translate(batchTexts, source: key, target: target.rawValue, partial: partial)
                        }
                        diagnosticBatch += 1
                        // 일본어가 아닌 대상 언어인데 번역이 비었거나 가나가 남아 돌아온 항목만, 같은 세션으로 문장·구 조각을 나눠 한 번 더 번역한다.
                        // 이미지 글자 번역(recognizeAndTranslate의 초기 후보 호출)에서만 켠다. 일반 웹 글자 경로는 그대로다.
                        if repairResidue, !LanguageDetection.isSameLanguage(target.rawValue, "ja") {
                            output = try await repairingResidue(output, sources: batchTexts, key: key, target: target, partial: partial,
                                                                context: OnboardDiagnostics.Context(requestID: diagnosticRequestID, batch: max(0, diagnosticBatch - 1),
                                                                                                    batches: diagnosticBatches))
                        }
                    }
                    for (offset, index) in chunk.enumerated() where offset < output.count {
                        results[index] = engine == BrowserRequest.localEngine && target == .korean
                            ? BrowserMenuTranslation.korean(texts[index]) ?? output[offset] : output[offset]
                    }
                } catch let failure as BrowserExternalFailure {
                    // 받은 결과는 유지한다. 언어 조합 실패는 그 묶음만, 그 밖의 실패는 남은 묶음을 보내지 않고 멈춘다.
                    for (offset, index) in chunk.enumerated() where offset < failure.results.count {
                        results[index] = failure.results[offset]
                    }
                    if warning == nil { warning = failure.message }
                    if failure.unsupported { break groupLoop }
                    if firstError == nil { firstError = BrowserEngineError.translationFailed(failure.message) }
                    break groups
                } catch BrowserEngineError.languageNotInstalled(let pair) {
                    missing.append(pair)
                    break groupLoop
                } catch BrowserEngineError.unsupportedPair {
                    break groupLoop
                } catch let error as CancellationError {
                    throw error
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    if firstError == nil { firstError = error }
                    break groupLoop
                }
            }
        }
        try Task.checkCancellation()
        if results.allSatisfy({ $0 == nil }) {
            if let firstError { throw firstError }
            if let pair = missing.first, missing.count == order.count { throw BrowserEngineError.languageNotInstalled(pair) }
        }
        return (results, missing, langs, warning)
    }

    /// 번역 한 번에 항목 전체가 비거나 원문 가나가 남아 돌아오면 그 항목은 통째로 쓸 수 없게 된다(확장은 원문을 그대로 두고 번역 확인 필요로 본다).
    /// 그런 항목만 골라(묶음당 최대 maxResidueRepairs개) 같은 세션으로 문장 단위, 그래도 가나가 남으면 구(띄어쓰기) 단위로 나눠
    /// 각각 한 번씩만 다시 번역한다. 가나가 줄어든 결과만 채택하고, 실패·취소가 아닌 오류는 처음 결과를 그대로 둔다. 반복 재시도는 없다.
    private static let maxResidueRepairs = 12

    private func repairingResidue(_ output: [String?], sources: [String], key: String, target: AppLanguage,
                                  partial: BrowserPartialHandler?, context: OnboardDiagnostics.Context) async throws -> [String?] {
        var current = output
        var pending: [Int] = []
        for (offset, source) in sources.enumerated() where offset < output.count {
            if target == .korean, BrowserMenuTranslation.korean(source) != nil { continue }
            let draft = (output[offset] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if draft.isEmpty || BrowserResidueRepair.kanaCount(draft) > 0 { pending.append(offset) }
            if pending.count >= Self.maxResidueRepairs { break }
        }
        for granularity in [BrowserResidueRepair.Granularity.sentence, .phrase] {
            var plan: [(offset: Int, segments: [String])] = []
            for offset in pending {
                let segments = BrowserResidueRepair.segments(sources[offset], granularity)
                if segments.count >= 2 { plan.append((offset, segments)) }
            }
            guard !plan.isEmpty else { continue }
            try Task.checkCancellation()
            let flat = plan.flatMap(\.segments)
            let translated: [String?]
            do {
                translated = try await OnboardDiagnostics.$context.withValue(context) {
                    try await translator.translate(flat, source: key, target: target.rawValue, partial: nil)
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                break
            }
            var cursor = 0
            for entry in plan {
                defer { cursor += entry.segments.count }
                var pieces: [String] = []
                var improvedAny = false
                for (k, segment) in entry.segments.enumerated() {
                    let text = cursor + k < translated.count
                        ? (translated[cursor + k] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    if !text.isEmpty && text != segment { improvedAny = true }
                    pieces.append(text.isEmpty ? segment : text)
                }
                let joined = pieces.joined(separator: " ")
                let draft = (current[entry.offset] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let baseline = draft.isEmpty ? BrowserResidueRepair.kanaCount(sources[entry.offset]) : BrowserResidueRepair.kanaCount(draft)
                guard improvedAny, BrowserResidueRepair.kanaCount(joined) < baseline else { continue }
                current[entry.offset] = joined
                partial?([(entry.offset, joined)])
            }
            pending = pending.filter { offset in
                let draft = (current[offset] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return draft.isEmpty || BrowserResidueRepair.kanaCount(draft) > 0
            }
        }
        return current
    }

    private func isSupported(_ key: String) -> Bool {
        guard let ids = supportedIDs, !ids.isEmpty else { return true }
        return ids.contains { LanguageDetection.isSameLanguage($0, key) }
    }

    // MARK: 다듬기 후속 요청 (앱 본체의 Chrome·Whale 전용, Mac 기본 번역 결과만)

    private struct RefineOutcome {
        var items: [String: String]
        var selected: Int
        var cacheHit: Int
        var fresh: Int
        var ms: Int
        /// ran_changed | ran_nochange | all_cached(전부 재사용 — 모델을 돌리지 않음)
        var outcome: String
    }

    /// 다듬기 요청의 개수·결과 코드만 비공개 로그에 남긴다(원문·번역문·주소 없음).
    private func recordRefine(selected: Int, hit: Int, fresh: Int, changed: Int, outcome: String, since start: ContinuousClock.Instant) {
        OnboardDiagnostics.record("refine", ["selected": selected, "cacheHit": hit, "fresh": fresh, "changed": changed,
                                             "outcome": outcome, "totalMs": OnboardDiagnostics.milliseconds(ContinuousClock.now - start)])
    }

    private func refineItems(_ items: [BrowserRefineItem], target: AppLanguage) async throws -> RefineOutcome {
        let start = ContinuousClock.now
        guard let refiner, refiner.isAvailable else {
            recordRefine(selected: items.count, hit: 0, fresh: 0, changed: 0, outcome: "unavailable", since: start)
            throw BrowserEngineError.refineFailed(.unavailable)
        }
        guard AppleTranslationRefiner.supportsTarget(target.rawValue) else {
            recordRefine(selected: items.count, hit: 0, fresh: 0, changed: 0, outcome: "unsupported_language", since: start)
            throw BrowserEngineError.refineFailed(.unsupportedLanguage)
        }
        // 재캡처·재배치 때 같은 그림의 같은 초안이 다시 오면 기기 내 모델을 다시 돌리지 않고 지난 결과(바꾸지 않음 포함)를 쓴다.
        var result: [String: String] = [:]
        var pending: [BrowserRefineItem] = []
        for item in items {
            if let hit = refineCache[Self.refineCacheKey(item, target: target)] {
                if let text = hit { result[item.key] = text }
            } else {
                pending.append(item)
            }
        }
        let hits = items.count - pending.count
        guard !pending.isEmpty else {
            recordRefine(selected: items.count, hit: hits, fresh: 0, changed: result.count, outcome: "all_cached", since: start)
            return RefineOutcome(items: result, selected: items.count, cacheHit: hits, fresh: 0,
                                 ms: OnboardDiagnostics.milliseconds(ContinuousClock.now - start), outcome: "all_cached")
        }
        let refined: [String: String]
        do {
            refined = try await refiner.refine(pending, targetLanguageName: target.displayNameKorean)
        } catch {
            // 실패는 캐시에 남기지 않는다(다음 요청이 다시 돈다).
            let code = (error as? AppleTranslationRefiner.Failure)?.rawValue ?? (error is CancellationError ? "cancelled" : "error")
            recordRefine(selected: items.count, hit: hits, fresh: pending.count, changed: 0, outcome: "failed_\(code)", since: start)
            throw error
        }
        for item in pending {
            let text = refined[item.key]
            if let text { result[item.key] = text }
            storeRefined(Self.refineCacheKey(item, target: target), text)
        }
        let outcome = result.isEmpty ? "ran_nochange" : "ran_changed"
        recordRefine(selected: items.count, hit: hits, fresh: pending.count, changed: result.count, outcome: outcome, since: start)
        return RefineOutcome(items: result, selected: items.count, cacheHit: hits, fresh: pending.count,
                             ms: OnboardDiagnostics.milliseconds(ContinuousClock.now - start), outcome: outcome)
    }

    /// 다듬기 결과 캐시: 메모리에만 두고(디스크·로그에 남기지 않음) 오래된 것부터 버린다. 기기 내 모델 결과만 담는다
    /// (웹 번역 엔진 결과는 다듬지 않으므로 여기에 들어오지 않는다). 값이 nil이면 "초안 그대로 둠"이다.
    private static let maxRefineCacheEntries = 512
    private var refineCache: [String: String?] = [:]
    private var refineCacheOrder: [String] = []

    private static func refineCacheKey(_ item: BrowserRefineItem, target: AppLanguage) -> String {
        [target.rawValue, item.original, item.draft, item.context ?? ""].joined(separator: "\u{1F}")
    }

    private func storeRefined(_ key: String, _ text: String?) {
        if refineCache.updateValue(text, forKey: key) == nil { refineCacheOrder.append(key) }
        while refineCacheOrder.count > Self.maxRefineCacheEntries {
            refineCache[refineCacheOrder.removeFirst()] = nil
        }
    }

    // MARK: 이미지 영역 OCR

    /// 보이는 탭 캡처에서 확장이 지정한 이미지 영역만 잘라 OCR하고, 번역된 조각의 위치(영역 기준 0...1)와 번역문만 돌려준다.
    /// 다섯 번째 결과는 단계별 걸린 시간(ms, 숫자만)이다. 원문·이미지는 담지 않는다.
    /// Mac 기본 번역은 글자 인식 직후 번역을 시작해, 원본 글자 픽셀 분석(배경 복원 조각)과 겹쳐 돌린다. 웹 번역 엔진은
    /// 분석으로 후리가나 등을 걸러낸 뒤 실제로 그릴 항목의 글자만 보낸다(바깥으로 보내는 글자를 늘리지 않는다).
    private func recognizeAndTranslate(_ imageData: Data, viewport: CGSize, regions: [BrowserImageRegionInput], calibration: CGRect?,
                                       target: AppLanguage, engine: String, pageTitle: String, companionTexts: [String] = [], progress: BrowserProgressHandler? = nil)
        async throws -> ([[String: Any]], [String], String?, CaptureCalibration, [String: Int], [String?]) {
        let clock = ContinuousClock()
        var mark = clock.now
        var timing: [String: Int] = [:]
        func lap(_ name: String) {
            let now = clock.now
            let elapsed = (now - mark).components
            timing[name] = Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
            mark = now
        }
        let itemLimit = engine == BrowserRequest.localEngine ? Self.maxOCRItems : Self.maxExternalOCRItems
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(imageData as CFData, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw BrowserEngineError.badRequest("이미지 해석")
        }
        guard width <= BrowserRequest.maxImageSide, height <= BrowserRequest.maxImageSide,
              width * height <= BrowserRequest.maxImagePixels else { throw BrowserEngineError.imageTooLarge }
        guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, options) else {
            throw BrowserEngineError.badRequest("이미지 해석")
        }
        // 이미 사용자가 선택한 외부 서비스만, 원문을 넣지 않은 채 OCR과 페이지 준비를 겹친다.
        // 제목 언어는 빈 화면의 초기 선택에만 쓰며, 실제 전송 언어는 인식한 글자로 다시 판별한다.
        if engine != BrowserRequest.localEngine, let external,
           case .language(let language) = LanguageDetection.classify(pageTitle) {
            if let reason = await external.unavailableReason(engine: engine) {
                throw BrowserEngineError.externalBlocked(reason)
            }
            try Task.checkCancellation()
            await external.prepare(source: language, target: target.rawValue, engine: engine)
        }
        lap("decode")
        let sx = Double(decoded.width) / Double(viewport.width)
        let sy = Double(decoded.height) / Double(viewport.height)
        let bounds = CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height)
        // 같은 캡처에 찍힌 보정 견본(CSS 0·128·255)의 실제 픽셀 값으로만 밝기를 되돌린다. 견본이 없거나 믿을 수 없으면 그대로 쓴다.
        let swatch = calibration.map { CGRect(x: $0.minX * sx, y: $0.minY * sy, width: $0.width * sx, height: $0.height * sy) }
        let (image, measured) = swatch.map { CaptureCalibration.apply(decoded, swatch: $0) } ?? (decoded, CaptureCalibration(status: "none"))
        // 견본 자리(가장자리 여유 포함)에 걸친 인식 결과는 견본 픽셀을 글자·배경으로 쓴 것일 수 있으므로 내보내지 않는다.
        let swatchGuard = swatch?.insetBy(dx: -8 * sx, dy: -8 * sy)
        lap("calibrate")

        // 1) 영역마다 글자 인식(문단 정리 포함). 원본 글자 픽셀 분석은 아래에서 따로 한다.
        struct Crop { let region: BrowserImageRegionInput; let rect: CGRect; let image: CGImage; let regions: [OCRRegion] }
        var crops: [Crop] = []
        var keys: [String] = []
        for region in regions {
            try Task.checkCancellation()
            keys.append(region.k)
            let rect = CGRect(x: region.x * sx, y: region.y * sy, width: region.w * sx, height: region.h * sy)
                .integral.intersection(bounds)
            guard !rect.isNull, rect.width >= 24, rect.height >= 24, let cropped = image.cropping(to: rect) else { continue }
            let rawText = try await ImageTextRecognizer.recognizeText(cropped, assetID: region.k, classifyFonts: false)
            let recognized = try await ImageTextRecognizer.recoveringTitles(rawText, pageTitle: pageTitle, image: cropped)
            crops.append(Crop(region: region, rect: rect, image: cropped, regions: recognized))
        }
        lap("ocr")
        // OCR 모델 적재와 경쟁하지 않게 인식 후 번역·배경 분석 동안 AI를 준비한다.
        if engine == BrowserRequest.localEngine && (refiner?.isAvailable ?? false) {
            Task { await AppleTranslationRefiner.prewarmBrowser(targetLanguageName: target.displayNameKorean) }
        }
        // 잘라낸 영역 기준 0...1 → 캡처 픽셀 좌표(견본 자리 대조용)
        func pixelRect(_ r: CGRect, in crop: CGRect) -> CGRect {
            CGRect(x: crop.minX + r.minX * crop.width, y: crop.minY + r.minY * crop.height,
                   width: r.width * crop.width, height: r.height * crop.height)
        }
        // 번역할 후보(분석 전 문단 기준). 견본 자리에 걸친 것은 뺀다.
        var candidateIDs = Set<String>()
        var candidateTexts: [String] = []
        var candidateIndex: [String: Int] = [:]
        scan: for crop in crops {
            for item in crop.regions where item.hasMeaningfulLetters {
                guard candidateTexts.count < itemLimit else { break scan }
                if let swatchGuard, swatchGuard.intersects(pixelRect(item.box, in: crop.rect)) { continue }
                candidateIDs.insert(item.id)
                candidateIndex[item.id] = candidateTexts.count
                candidateTexts.append(item.text)
            }
        }
        // 글자 인식이 끝난 즉시(번역·배경 복원 전에) 이번 캡처에서 알게 된 개수만 알린다: 요청한 이미지 수, 글자를 읽을 수
        // 있었던 이미지 수, 번역할 인식 문단(문장) 수, 그 문단의 공백 제외 글자 수. 원문은 담지 않는다.
        progress?(BrowserProgress(phase: "recognized", counts: [
            "images": regions.count, "recognizedImages": crops.filter { $0.regions.contains(where: \.hasMeaningfulLetters) }.count,
            "sentences": candidateTexts.count,
            "letters": candidateTexts.reduce(0) { $0 + $1.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count }
        ]))

        // 2) Mac 기본 번역은 지금 바로 시작해 분석과 겹친다(액터는 번역을 기다리는 동안 다른 일을 막지 않는다).
        let overlap = engine == BrowserRequest.localEngine && !candidateTexts.isEmpty
        var translateStart = clock.now
        let earlyTexts = candidateTexts
        // 번역이 분석보다 먼저 끝난 문단은 그 문단의 복원 조각이 준비되는 즉시(그림 단위로) 내보낸다. 다른 그림·번역 묶음을 기다리지 않는다.
        let streamBuffer: ImageStreamBuffer? = overlap ? progress.map { progress in
            ImageStreamBuffer(
                finalText: { source, draft in target == .korean ? BrowserImagePhraseTranslation.korean(source, draft: draft) : draft },
                deliver: { items in
                    var frame: [(key: String, dict: [String: Any])] = []
                    var frameCost = 0
                    func flush() {
                        guard !frame.isEmpty else { return }
                        var byKey: [String: [[String: Any]]] = [:]
                        var order: [String] = []
                        for entry in frame {
                            if byKey[entry.key] == nil { order.append(entry.key) }
                            byKey[entry.key, default: []].append(entry.dict)
                        }
                        let images = order.map { ["k": $0, "items": byKey[$0] ?? []] as [String: Any] }
                        if let data = try? JSONSerialization.data(withJSONObject: images) {
                            progress(BrowserProgress(phase: "partial", images: data))
                        }
                        frame.removeAll()
                        frameCost = 0
                    }
                    // 한 프레임이 약 500KB를 넘지 않게 나눈다(프레임 상한은 1MB).
                    for item in items {
                        let cost = ((item.dict["m"] as? [String: Any])?["d"] as? String)?.utf8.count ?? 0
                        if frameCost > 0, frameCost + cost > 500_000 { flush() }
                        frame.append(item)
                        frameCost += cost + 8_000
                    }
                    flush()
                })
        } : nil
        let earlyProgress: BrowserProgressHandler? = progress.map { progress in
            { @Sendable update in
                if update.phase == "partial" { streamBuffer?.receive(update.items) } else { progress(update) }
            }
        }
        async let early: ([String?], [String], [String?], String?)? = overlap
            ? try await translateTexts(earlyTexts, target: target, engine: engine, progress: earlyProgress, repairResidue: true) : nil

        // 3) 원본 글자 픽셀 분석·배경 복원 조각(영역마다 동시에, 액터 밖에서). 영역 하나의 분석이 끝나는 즉시 그 문단들을 내보낼 수 있게 준비한다.
        struct Found {
            let imageKey: String; let id: String; let box: CGRect; let text: String; let bg: String; let fg: String
            /// box와 같은 요청 영역 기준 0...1 좌표로 변환한 원본 글자 상자(마스킹·글꼴 추정용)
            let glyphBoxes: [CGRect]
            /// glyphBoxes와 같은 순서·개수의 인식 글자(비어 있을 수 있다). 본문 글자 크기 표본을 고르는 데만 쓴다.
            let glyphTexts: [String]
            /// glyphBoxes 밖에서 함께 지운 상자(후리가나 등, 요청 영역 기준 0...1). 복원 조각을 못 쓸 때 대신 가린다.
            let coverBoxes: [CGRect]
            /// 원본 글자 모양으로 추정한 글꼴 갈래("gothic"/"myeongjo"/"gungseo"/"hand"). 미판별이면 nil.
            let fontStyle: String?
            /// 원본 글자 픽셀 분석(굵기·테두리색·배경 복원 조각). 복원 조각 위치는 요청 영역 기준 0...1로 변환해 둔다.
            let typography: GlyphTypography?
            let restorationBox: CGRect?
        }
        func rounded(_ value: CGFloat) -> Double { (Double(value) * 10_000).rounded() / 10_000 }
        func boxes(_ list: [CGRect]) -> [[Double]] { list.map { [rounded($0.minX), rounded($0.minY), rounded($0.width), rounded($0.height)] } }
        let candidateIDSet = candidateIDs
        // 영역 하나의 인식·분석 결과를 번역 후보 문단(Found)으로 바꾼다.
        func foundItems(in crop: Crop, recognized: [OCRRegion]) -> [Found] {
            let region = crop.region, rect = crop.rect
            // 잘라낸 픽셀 좌표 → 뷰포트 CSS 좌표 → 요청 영역 기준 0...1. item.box와 글자 상자 모두 같은 변환을 쓴다.
            func mapRect(_ r: CGRect) -> CGRect {
                let px = (rect.minX + r.minX * rect.width) / sx
                let py = (rect.minY + r.minY * rect.height) / sy
                let pw = r.width * rect.width / sx
                let ph = r.height * rect.height / sy
                return CGRect(x: (px - region.x) / region.w, y: (py - region.y) / region.h,
                             width: pw / region.w, height: ph / region.h)
            }
            var result: [Found] = []
            for item in recognized where candidateIDSet.contains(item.id) {
                if let swatchGuard, item.typography?.restorationBox.map({ swatchGuard.intersects(pixelRect($0, in: rect)) }) ?? false {
                    continue
                }
                result.append(Found(imageKey: region.k, id: item.id, box: mapRect(item.box), text: item.text, bg: item.backgroundHex,
                                    fg: item.typography?.foregroundHex ?? item.foregroundHex,
                                    glyphBoxes: item.glyphBoxes.map(mapRect), glyphTexts: item.glyphTexts,
                                    coverBoxes: (item.typography?.coverBoxes ?? item.annotationBoxes).map(mapRect),
                                    fontStyle: item.fontStyle, typography: item.typography,
                                    restorationBox: item.typography?.restorationBox.map(mapRect)))
            }
            return result
        }
        // 문단 하나의 응답 항목(번역문 "t"는 번역이 끝난 뒤에 채운다). id는 이번 요청 안에서 문단마다 유일한 인식 식별자로,
        // 번역문과 무관하게 확장이 같은 문단의 반복·재시도 결과를 한 항목으로 합치는 데 쓴다.
        // 응답 전체(이 recognizeAndTranslate 호출 하나)에서 보내는 글자 상자(g·cv) 총 개수 상한은 glyphBudget으로 이어 센다. 항목별 128개
        // 상한(ImageTextRecognizer.maxGlyphsPerItem)은 그대로 둔 채, 번역에 성공해 실제로 내보내는 항목만 이
        // 예산을 소모한다. 전체 응답은 여전히 BrowserBridge.maxOutgoingFrame(1MB)로 보호된다.
        func responseItem(_ item: Found, glyphBudget: inout Int) -> [String: Any] {
            var dict: [String: Any] = [
                "id": String(item.id.prefix(64)),
                "x": rounded(item.box.minX), "y": rounded(item.box.minY),
                "w": rounded(item.box.width), "h": rounded(item.box.height),
                "t": "", "bg": item.bg, "fg": item.fg,
                // 다듬기 후속 요청에만 쓰는 인식 원문(짧게 자름). Chrome·Whale에서 아이콘·화면 번역과 달리
                // 이 원문을 저장하거나 기록하지 않고, 같은 패스의 후속 요청 한 번에만 메모리에서 쓴다.
                "o": String(item.text.prefix(700))
            ]
            // 원본 글자 모양으로 추정한 글꼴 갈래("fs"). 미판별이면 생략(확장이 고딕으로 대체).
            if let fontStyle = item.fontStyle { dict["fs"] = fontStyle }
            // 원본이 굵은 글씨("fw": 700)·테두리 글씨("oc": 테두리색)일 때만 보낸다. "fg"는 위에서 실측 글자색으로 바뀌어 있다.
            if item.typography?.bold == true { dict["fw"] = 700 }
            if let outline = item.typography?.outlineHex { dict["oc"] = outline }
            // 원본 글자 상자([x,y,w,h] 배열의 배열). 글자 크기 산정과, 복원 조각을 못 쓸 때의 대체 가림에 쓴다.
            if !item.glyphBoxes.isEmpty && item.glyphBoxes.count <= glyphBudget {
                dict["g"] = boxes(item.glyphBoxes)
                glyphBudget -= item.glyphBoxes.count
                // "g"와 같은 순서의 본문 글자 표시("1": 글자·숫자, "0": 구두점·기호). 확장은 글자 크기를 "1"만으로 잰다.
                if item.glyphTexts.count == item.glyphBoxes.count {
                    dict["gl"] = String(item.glyphTexts.map { $0.contains { $0.isLetter || $0.isNumber } ? "1" : "0" })
                }
            }
            // "g" 밖에서 함께 지운 상자(후리가나·위치를 못 잡은 글자의 문단 영역). 대체 가림에만 쓴다.
            if !item.coverBoxes.isEmpty && item.coverBoxes.count <= glyphBudget {
                dict["cv"] = boxes(item.coverBoxes)
                glyphBudget -= item.coverBoxes.count
            }
            if let uncovered = item.typography?.uncoveredGlyphs, uncovered > 0 { dict["uc"] = uncovered }
            return dict
        }
        let patchPrefix = "data:image/png;base64,"
        // 부분 전송용 항목: 복원 조각을 항목당 약 400KB 안에서 바로 싣는다(최종 응답이 전체 예산으로 다시 정한다).
        func readyEntries(_ items: [Found]) -> [ImageStreamBuffer.Entry] {
            var budget = Self.maxOutgoingGlyphBoxes
            return items.compactMap { item -> ImageStreamBuffer.Entry? in
                guard let k = candidateIndex[item.id] else { return nil }
                var dict = responseItem(item, glyphBudget: &budget)
                if let original = item.typography?.restorationPNG, let patch = item.restorationBox {
                    let limit = 400_000
                    var png: Data? = original
                    if patchPrefix.count + (original.count + 2) / 3 * 4 > limit {
                        png = Self.downscaledPatch(original, maxBytes: max(0, limit - patchPrefix.count) / 4 * 3)
                    }
                    if let png {
                        dict["m"] = ["x": rounded(patch.minX), "y": rounded(patch.minY), "w": rounded(patch.width),
                                     "h": rounded(patch.height), "d": patchPrefix + png.base64EncodedString()]
                    }
                }
                return ImageStreamBuffer.Entry(index: k, key: item.imageKey, dict: dict, source: item.text)
            }
        }
        let analyzeStart = clock.now
        var foundByCrop = Array(repeating: [Found](), count: crops.count)
        // 분석은 영역마다 동시에 돌고, 문단(말풍선 단위로 묶인 인식 항목) 하나의 분석이 끝나는 즉시 이벤트로 넘어온다. 이 반복문이
        // 그 문단을 바로 내보내므로 같은 그림의 다른 문단이나 다른 그림의 분석이 끝나기를 기다리지 않는다.
        enum AnalysisEvent: Sendable { case region(Int, OCRRegion); case finished(Int, [OCRRegion]) }
        let (events, eventSink) = AsyncStream<AnalysisEvent>.makeStream()
        _ = await withTaskGroup(of: Void.self) { group in
            for (index, crop) in crops.enumerated() {
                // 모든 문단을 재되(후리가나 판정·다른 글자 자리 제외에 필요), 복원 조각은 번역 후보만 만든다.
                let picture = crop.image, recognized = crop.regions, restore = candidateIDSet
                group.addTask {
                    let analyzed = ImageTextRecognizer.analyzed(recognized, image: picture, restoration: true, restoreIDs: restore,
                                                                onRegion: { eventSink.yield(.region(index, $0)) })
                    eventSink.yield(.finished(index, analyzed))
                }
            }
            var pending = crops.count
            var delivered = Set<String>()
            if pending == 0 { eventSink.finish() }
            for await event in events {
                switch event {
                case .region(let index, let region):
                    // 이미 번역된 문단은 지금 바로 나가고, 아직 번역 중인 문단은 번역이 끝나는 즉시 나간다.
                    let items = foundItems(in: crops[index], recognized: [region])
                    delivered.insert("\(index):\(region.id)")
                    streamBuffer?.addReady(readyEntries(items))
                case .finished(let index, let regions):
                    let items = foundItems(in: crops[index], recognized: regions)
                    foundByCrop[index] = items
                    // 문단 단위 알림 없이 끝난 영역(분석 불가 등)의 문단은 여기서 한꺼번에 내보낸다.
                    streamBuffer?.addReady(readyEntries(items.filter { delivered.insert("\(index):\($0.id)").inserted }))
                    pending -= 1
                    if pending == 0 { eventSink.finish() }
                }
            }
        }
        timing["analyze"] = { let c = (clock.now - analyzeStart).components
            return Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000) }()
        try Task.checkCancellation()

        let found: [Found] = foundByCrop.flatMap { $0 }
        var glyphBudget = Self.maxOutgoingGlyphBoxes
        var drawn: [(key: String, dict: [String: Any], item: Found)] = []
        // 번역문("t")은 번역이 끝난 뒤에 채운다(문단별 부분 전송과 최종 응답이 같은 항목을 쓴다).
        for item in found {
            drawn.append((item.imageKey, responseItem(item, glyphBudget: &glyphBudget), item))
        }
        // 원문을 덮는 PNG 조각("m"). 조각을 뺀 응답 크기를 먼저 재고 남은 프레임 여유(1MB 상한)만큼만 싣는다.
        // 싣지 못한 항목은 확장이 g·cv 상자를 문단 배경색으로 불투명하게 가린다(원문이 비치지 않게).
        // 번역문은 아직 비어 있으므로 원문 길이 기준으로 글자당 3바이트씩 미리 떼어 둔다.
        var restorationBudget = Self.maxOutgoingRestorationCharacters
        if let base = try? JSONSerialization.data(withJSONObject: drawn.map(\.dict)) {
            let translationReserve = found.reduce(0) { $0 + 3 * min($1.text.count * 2 + 16, 1_500) }
            restorationBudget = max(0, min(BrowserBridge.maxOutgoingFrame - base.count - translationReserve - 32_000,
                                           Self.maxOutgoingRestorationCharacters))
        }
        // 앞에서부터 들어가는 대로 싣던 방식은 큰 제목 조각 몇 개가 여유를 다 쓰거나, 남은 여유보다 큰 조각을 통째로 빼
        // 그 항목이 글자 상자 단색 가림(큰 평면 상자)으로 떨어졌다. 작은 조각부터 남은 여유를 남은 개수로 나눈 몫 안에서
        // 원래 해상도로 싣고, 몫보다 큰 조각은 해상도만 낮춰(지운 픽셀은 불투명 유지) 싣는다.
        let prefix = patchPrefix
        let patched = drawn.indices.compactMap { index -> (Int, Data, CGRect)? in
            guard let png = drawn[index].item.typography?.restorationPNG, let patch = drawn[index].item.restorationBox else { return nil }
            return (index, png, patch)
        }.sorted { $0.1.count < $1.1.count }
        for (k, (index, original, patch)) in patched.enumerated() {
            let share = restorationBudget / (patched.count - k)
            var png = original
            if prefix.count + (png.count + 2) / 3 * 4 > share,
               let smaller = Self.downscaledPatch(png, maxBytes: max(0, share - prefix.count) / 4 * 3) {
                png = smaller
            }
            let encoded = prefix + png.base64EncodedString()
            guard encoded.count <= restorationBudget else { continue }
            drawn[index].dict["m"] = ["x": rounded(patch.minX), "y": rounded(patch.minY), "w": rounded(patch.width),
                                      "h": rounded(patch.height), "d": encoded]
            restorationBudget -= encoded.count
        }


        // 4) 번역 결과 모으기
        var companionResults = [String?](repeating: nil, count: companionTexts.count)
        var translated = [String?](repeating: nil, count: found.count)
        var missing: [String] = []
        var langs = [String?](repeating: nil, count: found.count)
        var warning: String?
        if overlap, let result = try await early {
            for (index, item) in found.enumerated() {
                guard let k = candidateIndex[item.id], k < result.0.count else { continue }
                translated[index] = result.0[k]
                langs[index] = k < result.2.count ? result.2[k] : nil
            }
            (missing, warning) = (result.1, result.3)
        } else if !found.isEmpty || !companionTexts.isEmpty {
            // 일반 글자와 새로 인식한 글자를 같은 언어 묶음에 넣어 서비스 준비를 반복하지 않는다.
            var combined: [String] = []
            var indexes: [String: Int] = [:]
            for text in companionTexts + found.map(\.text) where indexes[text] == nil {
                indexes[text] = combined.count
                combined.append(text)
            }
            // 웹 번역은 분석 뒤에 시작한다. 준비·복원 시간을 번역 시간에 중복 합산하지 않는다.
            translateStart = clock.now
            do {
                let response = try await translateTexts(combined, target: target, engine: engine, progress: progress)
                (missing, warning) = (response.1, response.3)
                companionResults = companionTexts.map { text in indexes[text].flatMap { response.0[$0] } }
                translated = found.map { item in indexes[item.text].flatMap { response.0[$0] } }
                langs = found.map { item in indexes[item.text].flatMap { response.2[$0] } }
            } catch BrowserEngineError.translationFailed(let reason) where engine != BrowserRequest.localEngine {
                // 웹 번역 엔진이 도중에 멈춰 받은 결과가 하나도 없을 때: 요청 전체를 오류로 끝내면 덮개가 없어 원문 글자가 그대로
                // 드러난다. 원문을 가린 채 빈 번역(확장의 "번역 확인 필요" 표시)과 실패 사유를 돌려준다. 동의 없음·연결 불가는 그대로 오류다.
                warning = reason
            }
        }
        timing["translate"] = found.isEmpty && companionTexts.isEmpty ? 0 : { let c = (clock.now - translateStart).components
            return Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000) }()
        mark = clock.now

        for (index, text) in zip(found.indices, translated) {
            let draft = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let finalText = engine == BrowserRequest.localEngine && target == .korean && !draft.isEmpty
                ? BrowserImagePhraseTranslation.korean(found[index].text, draft: draft) : draft
            drawn[index].dict["t"] = finalText
        }
        var itemsByKey: [String: [[String: Any]]] = [:]
        for entry in drawn { itemsByKey[entry.key, default: []].append(entry.dict) }
        // 원화 환산 후보: 번역 조각이 없는 줄(숫자·통화 기호만 있어 번역 대상이 아닌 가격 줄 등)의 위치·인식 원문·글자 상자만 따로 보낸다.
        // 확장은 이 줄에서 외국 금액을 찾아 금액 바로 아래에 말풍선을 놓는다(번역문·가림 조각은 없고 원본 그림은 그대로).
        // 글자 상자는 인식 원문의 공백 아닌 글자와 개수까지 맞을 때만 싣는다(맞지 않으면 확장이 줄 상자 비율로 대신한다).
        var fxByKey: [String: [[String: Any]]] = [:]
        for crop in crops {
            let region = crop.region, rect = crop.rect
            func mapFXRect(_ r: CGRect) -> CGRect {
                let px = (rect.minX + r.minX * rect.width) / sx
                let py = (rect.minY + r.minY * rect.height) / sy
                return CGRect(x: (px - region.x) / region.w, y: (py - region.y) / region.h,
                              width: r.width * rect.width / sx / region.w, height: r.height * rect.height / sy / region.h)
            }
            for item in crop.regions where !candidateIDs.contains(item.id) && CurrencyParser.mightContainAmount(item.text) {
                if let swatchGuard, swatchGuard.intersects(pixelRect(item.box, in: rect)) { continue }
                guard fxByKey[region.k, default: []].count < 48 else { break }
                let box = mapFXRect(item.box)
                var dict: [String: Any] = ["x": rounded(box.minX), "y": rounded(box.minY), "w": rounded(box.width), "h": rounded(box.height),
                                           "o": String(item.text.prefix(300))]
                // 글자마다 정확한 상자를 싣는다: 순서대로 맞는 상자만 쓰고 빠진 글자는 이웃 상자 사이로 보간한다(문단 크기 추정을 피함).
                let letters = item.text.filter { !$0.isWhitespace }
                if item.text.count <= 300, letters.count <= glyphBudget,
                   let aligned = CurrencyBubbleLayout.alignedGlyphBoxes(text: item.text, glyphBoxes: item.glyphBoxes, glyphTexts: item.glyphTexts) {
                    dict["g"] = boxes(aligned.map(mapFXRect))
                    dict["gl"] = String(letters.map { $0.isLetter || $0.isNumber ? "1" : "0" })
                    glyphBudget -= aligned.count
                }
                fxByKey[region.k, default: []].append(dict)
            }
        }
        // 번역 성공 여부와 무관하게(건너뛴 조각 포함) 이미지마다 인식한 언어 개수를 센다.
        var langCountsByKey: [String: [String: Int]] = [:]
        for (item, lang) in zip(found, langs) {
            guard let lang else { continue }
            langCountsByKey[item.imageKey, default: [:]][lang, default: 0] += 1
        }
        let images: [[String: Any]] = keys.map { key in
            var image: [String: Any] = ["k": key, "items": itemsByKey[key] ?? [], "langs": langCountsByKey[key] ?? [:]]
            if let fx = fxByKey[key], !fx.isEmpty { image["fx"] = fx }
            return image
        }
        lap("encode")
        return (images, missing, warning, measured, timing, companionResults)
    }

    /// 배경 복원 조각 PNG를 maxBytes 안에 들어가도록 해상도만 낮춘다(확장은 같은 자리 m.x·y·w·h에 늘려 그린다).
    /// 줄이면 지운 픽셀 가장자리가 반투명해져 원문이 비치므로, 조금이라도 덮인 픽셀은 불투명으로 되돌리고(색은 덮인
    /// 픽셀 평균) 이웃 한 칸(8방향)을 더 불투명하게 넓혀, 늘려 그릴 때의 반투명 띠가 원래 지운 자리 밖에만 생기게 한다.
    /// 못 줄이면 nil(호출자가 조각을 싣지 않는다).
    static func downscaledPatch(_ png: Data, maxBytes: Int) -> Data? {
        guard maxBytes >= 512, let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var scale = min(0.9, (Double(maxBytes) / Double(max(1, png.count))).squareRoot() * 0.9)
        for _ in 0..<3 {
            let w = Int(Double(image.width) * scale), h = Int(Double(image.height) * scale)
            guard w >= 2, h >= 2 else { return nil }
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { return nil }
            var opaque = [Bool](repeating: false, count: w * h)
            for i in 0..<(w * h) {
                let a = Int(pixels[i * 4 + 3])
                guard a > 0 else { continue }
                opaque[i] = true
                if a < 255 {
                    for c in 0..<3 { pixels[i * 4 + c] = UInt8(min(255, Int(pixels[i * 4 + c]) * 255 / a)) }
                    pixels[i * 4 + 3] = 255
                }
            }
            var output = pixels
            for y in 0..<h {
                for x in 0..<w where !opaque[y * w + x] {
                    neighbors: for dy in -1...1 {
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let xx = x + dx, yy = y + dy
                            guard xx >= 0, yy >= 0, xx < w, yy < h, opaque[yy * w + xx] else { continue }
                            let s = (yy * w + xx) * 4, d = (y * w + x) * 4
                            output[d] = pixels[s]; output[d + 1] = pixels[s + 1]; output[d + 2] = pixels[s + 2]; output[d + 3] = 255
                            break neighbors
                        }
                    }
                }
            }
            let data = NSMutableData()
            guard let provider = CGDataProvider(data: Data(output) as CFData),
                  let scaled = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
                  let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, scaled, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if data.length <= maxBytes { return data as Data }
            scale *= max(0.5, (Double(maxBytes) / Double(data.length)).squareRoot() * 0.9)
        }
        return nil
    }

    // MARK: 인코딩

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? BrowserBridge.errorFrame(code: "internal", message: "응답을 만들지 못했습니다.")
    }

    private static func encodeError(_ error: Error, id: String?) -> Data {
        if let engineError = error as? BrowserEngineError {
            return BrowserBridge.errorFrame(code: engineError.code, message: engineError.message, id: id)
        }
        return BrowserBridge.errorFrame(code: "translation_failed", message: describe(error), id: id)
    }

    static func describe(_ error: Error) -> String {
        if TranslationError.unsupportedLanguagePairing ~= error { return "Mac 기본 번역이 지원하지 않는 언어 조합입니다." }
        if TranslationError.unableToIdentifyLanguage ~= error { return "언어를 판별하지 못했습니다." }
        if #available(macOS 26.0, *), TranslationError.notInstalled ~= error {
            return "번역 언어 팩이 설치되지 않았습니다. 시스템 설정 › 일반 › 언어 및 지역 › 번역 언어에서 내려받으세요."
        }
        return "번역 실패: \(error.localizedDescription)"
    }
}

// MARK: - 캡처 밝기 보정(같은 캡처에 찍힌 CSS 견본 기준)

/// 확장이 캡처 직전 화면 가장자리에 CSS로 정확히 그린 견본(검정 0·회색 128·흰색 255, 같은 너비 세 칸이 가로로 나란히)을
/// 실제 캡처 픽셀에서 읽은 결과. 근거는 CSS 값과 같은 자리의 캡처 픽셀 값 쌍뿐이며, 그림 속 밝은 색을 흰색으로 짐작하지 않는다.
/// 캡처가 어둡게 찍힌 원인(HDR 등)은 확정하지 않는다. 선형광에서 일정 비율로 어두워진 관계가 견본으로 확인될 때만 되돌린다.
struct CaptureCalibration {
    static let levels: [Double] = [0, 128, 255]
    /// "applied"(되돌림) / "normal"(흰색이 이미 흰색) / "rejected"(견본을 믿을 수 없음) / "none"(견본 없음)
    let status: String
    var black: Int?
    var gray: Int?
    var white: Int?

    /// 응답에 싣는 진단 값(측정한 세 칸의 대표값). 이미지 픽셀이나 내용은 담지 않는다.
    var dictionary: [String: Any] {
        var result: [String: Any] = ["s": status]
        if let black, let gray, let white { result["b"] = black; result["g"] = gray; result["w"] = white }
        return result
    }

    private static func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    private static func encoded(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    /// 이미지를 sRGB RGBA 바이트로 그린다(행 0이 위).
    private static func rgba(_ image: CGImage, space: CGColorSpace) -> [UInt8]? {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? bytes : nil
    }

    /// swatch: 캡처 픽셀 좌표의 견본 자리. 견본이 고르고 무채색이며 세 값이 단조이고, 회색이 "흰색 비율로 어두워진 128"과
    /// 선형광에서 맞을 때만 흰색 견본 값을 255로 되돌리는 선형광 이득을 이미지 전체에 적용한다. 그 밖에는 원본 그대로 돌려준다.
    static func apply(_ image: CGImage, swatch: CGRect) -> (CGImage, CaptureCalibration) {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let rejected = CaptureCalibration(status: "rejected")
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), swatch.width >= 9, swatch.height >= 3 else { return (image, rejected) }
        let crop = swatch.integral
        guard bounds.contains(crop), let piece = image.cropping(to: crop), let bytes = rgba(piece, space: space) else { return (image, rejected) }
        let pw = piece.width, ph = piece.height
        let cellWidth = swatch.width / Double(levels.count)
        var values: [Double] = []
        for index in levels.indices {
            // 칸 가장자리의 JPEG 번짐을 피해 가운데 40%만 표본으로 쓴다.
            let x0 = Int((swatch.minX - crop.minX + (Double(index) + 0.3) * cellWidth).rounded(.up))
            let x1 = Int((swatch.minX - crop.minX + (Double(index) + 0.7) * cellWidth).rounded(.down))
            let y0 = Int((swatch.minY - crop.minY + 0.3 * swatch.height).rounded(.up))
            let y1 = Int((swatch.minY - crop.minY + 0.7 * swatch.height).rounded(.down))
            guard x0 >= 0, y0 >= 0, x1 <= pw, y1 <= ph, (x1 - x0) * (y1 - y0) >= 9 else { return (image, rejected) }
            var reds: [UInt8] = [], greens: [UInt8] = [], blues: [UInt8] = [], means: [Int] = []
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = (y * pw + x) * 4
                    reds.append(bytes[i]); greens.append(bytes[i + 1]); blues.append(bytes[i + 2])
                    means.append((Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2])) / 3)
                }
            }
            func median(_ list: [UInt8]) -> Int { Int(list.sorted()[list.count / 2]) }
            let channels = [median(reds), median(greens), median(blues)]
            means.sort()
            // 고르지 않거나(가려짐·자리 어긋남) 무채색이 아니면(색 있는 덮개·필터) 믿지 않는다.
            let spread = means[means.count * 9 / 10] - means[means.count / 10]
            guard spread <= 24, channels.max()! - channels.min()! <= 24 else { return (image, rejected) }
            values.append(Double(channels.reduce(0, +)) / 3)
        }
        let (b, g, w) = (values[0], values[1], values[2])
        var result = CaptureCalibration(status: "rejected", black: Int(b.rounded()), gray: Int(g.rounded()), white: Int(w.rounded()))
        // 검정은 검정 근처, 세 값은 뚜렷이 단조, 흰색은 지나치게 어둡지 않아야 한다(너무 어두우면 되돌리는 이득이 과하다).
        guard b <= 48, w >= 96, g - b >= 16, w - g >= 16 else { return (image, result) }
        guard w < 250 else { return (image, CaptureCalibration(status: "normal", black: result.black, gray: result.gray, white: result.white)) }
        // 선형광 비율 모델: 캡처(선형) = k × 화면(선형). 흰색 견본으로 k를 정하고, 회색 견본이 k × linear(128/255)와 맞는지 본다.
        let k = linear(w / 255)
        let ratio = linear(g / 255) / (k * linear(levels[1] / 255))
        guard ratio >= 0.7, ratio <= 1.4, let pixels = rgba(image, space: space) else { return (image, result) }
        let gain = 1 / k
        let table = (0..<256).map { UInt8(min(255, (encoded(min(1, linear(Double($0) / 255) * gain)) * 255).rounded())) }
        var corrected = pixels
        for i in Swift.stride(from: 0, to: corrected.count, by: 4) {
            corrected[i] = table[Int(corrected[i])]; corrected[i + 1] = table[Int(corrected[i + 1])]; corrected[i + 2] = table[Int(corrected[i + 2])]
        }
        guard let provider = CGDataProvider(data: Data(corrected) as CFData),
              let output = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: image.width * 4, space: space,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return (image, result) }
        result = CaptureCalibration(status: "applied", black: result.black, gray: result.gray, white: result.white)
        return (output, result)
    }
}

// MARK: - macOS 26 이상: 화면 없이 쓰는 기기 내 번역 세션

/// 짧은 게임 메뉴는 문맥 없이도 뜻이 확정된다. 일반 문장·작품명에는 적용하지 않는다.
enum BrowserMenuTranslation {
    static func korean(_ source: String) -> String? {
        switch source.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "はじめから", "初めから": return "처음부터"
        case "つづきから", "続きから": return "이어하기"
        case "GAME OVER", "ゲームオーバー": return "게임 오버"
        default: return nil
        }
    }
}

/// 번역문에 원문 가나가 남았는지 세고, 그런 항목을 다시 번역할 때 원문을 문장·구 조각으로 나눈다(원문 내용은 기록하지 않는다).
enum BrowserResidueRepair {
    enum Granularity { case sentence, phrase }

    /// 확장 content.js의 KANA_RESIDUE와 같은 범위(장음 부호·가운뎃점 제외).
    static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3041...0x3096, 0x309D...0x309F, 0x30A1...0x30FA, 0x30FD...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF6F, 0xFF71...0xFF9D: return true
        default: return false
        }
    }

    static func kanaCount(_ text: String) -> Int { text.unicodeScalars.reduce(0) { $0 + (isKana($1) ? 1 : 0) } }

    /// sentence: 문장 끝 부호 뒤에서, phrase: 공백·줄바꿈에서 자른다. 글자가 없는 조각은 앞 조각에 붙인다.
    static func segments(_ source: String, _ granularity: Granularity) -> [String] {
        var raw: [String] = []
        var buffer = ""
        var pendingBreak = false
        for character in source {
            let isTerminator = "。．.！!？?…‥".contains(character)
            switch granularity {
            case .sentence:
                if pendingBreak && !isTerminator && !"」』）)”’".contains(character) {
                    raw.append(buffer); buffer = ""; pendingBreak = false
                }
                buffer.append(character)
                if isTerminator { pendingBreak = true }
            case .phrase:
                if character.isWhitespace {
                    if !buffer.isEmpty { raw.append(buffer); buffer = "" }
                } else {
                    buffer.append(character)
                }
            }
        }
        if !buffer.isEmpty { raw.append(buffer) }
        var result: [String] = []
        for piece in raw {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) || result.isEmpty {
                result.append(trimmed)
            } else {
                result[result.count - 1] += trimmed
            }
        }
        return result
    }
}

/// 게임·만화의 짧은 표기는 단독 번역에서 장르와 제작진을 낱말 뜻으로 잘못 옮긴다.
/// 정확히 일치하는 이미지 문구와 명시된 게임 직업만 보완하며 외부 번역 결과에는 적용하지 않는다.
enum BrowserImagePhraseTranslation {
    // 출판사가 저자 소개에 명시한 가나 읽기만 사용한다. 한자 이름의 발음을 추측하지 않는다.
    // https://www.kodansha.co.jp/comic/products/0000428665
    static let creditNames: [(source: String, korean: String, variants: String)] = [
        ("八又ナガト", "야마타 나가토", #"(?:야마타|하치마타|야와시)\s*나가토"#),
        ("阿倍野ちゃこ", "아베노 차코", #"(?:아베노|아배노)\s*(?:차코|카코)"#),
        ("天王寺きつね", "텐노지 키츠네", #"텐노지\s*(?:키츠네|여우)"#)
    ]

    static func exactKorean(_ source: String) -> String? {
        switch source.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "死にゲー": return "죽음을 반복하는 게임"
        case "最強布陣で描く": return "최강의 제작진이 그리는"
        case "次世代覇権の異世界転生新連載": return "차세대를 이끌 이세계 전생 신작 연재"
        default: return nil
        }
    }

    static func korean(_ source: String, draft: String) -> String {
        if let exact = exactKorean(source) { return exact }
        var result = draft
        let compactSource = String(source.filter { !$0.isWhitespace })
        for name in creditNames where compactSource.contains(name.source) {
            result = result.replacingOccurrences(of: "(?<![가-힣])" + name.variants +
                "(?=$|[^가-힣]|(?:에게|으로|은|는|이|가|을|를|와|과|의|로)(?:$|[^가-힣]))",
                                                 with: name.korean, options: .regularExpression)
        }
        // 같은 명사에 붙은 숫자가 인식으로 확인된 경우만 보존한다. 혈액형 등의 문자O는 바꾸지 않는다.
        if source.replacingOccurrences(of: " ", with: "").contains("犠牲者0") {
            result = result.replacingOccurrences(of: #"희생자\s*O(?=의|\s|$)"#, with: "희생자 0", options: .regularExpression)
        }
        if source.contains("死にゲー") {
            result = result.replacingOccurrences(of: "죽음 게임", with: "죽음을 반복하는 게임")
        }
        // 작품 속 평범한 등장인물로 환생하는 モブ를 몬스터처럼 옮기지 않는다.
        if source.contains("モブに転生"), !source.contains("モンスター"), !source.contains("魔物") {
            result = result.replacingOccurrences(of: #"(?<![가-힣])(?:몹|모브)(?:으로|로)(\s*)(?=환생|전생)"#,
                                                 with: "엑스트라로$1", options: .regularExpression)
        }
        if source.contains("外れジョブ"), source.contains("ヒーラー") {
            for mistaken in ["외래직업", "외래 직업", "비정형 직업"] {
                result = result.replacingOccurrences(of: mistaken, with: "꽝 직업")
            }
        }
        // 辿り着け는 도달했다는 서술이 아니라 명령이다. 늘인 소리·대시를 포함한
        // 문장 끝에서만 확인하고, 이미 번역된 앞부분과 다른 동사는 그대로 둔다.
        if hasReachImperative(source) {
            let stretched = source.range(of: #"辿り着け[ー—―−\-~～]+[!.。！\s]*$"#, options: .regularExpression) != nil
            result = result.replacingOccurrences(
                of: #"(도달|도착)(?:했어|했습니다|했다|했어요|하세요|하라|해)[~～ー—―−\-!.。！\s]*$"#,
                with: stretched ? "$1해라—" : "$1해라", options: .regularExpression)
        }
        return result
    }

    static func hasReachImperative(_ source: String) -> Bool {
        source.range(of: #"辿り着け[ー—―−\-~～!.。！\s]*$"#, options: .regularExpression) != nil
    }
}

/// 진단 전용: 온보드 번역 요청의 실제 선택 전략·실패 사유·구간 시간을 JSON Lines로 남긴다(동작에는 영향 없음).
/// 원문·번역문·URL·이미지·자격 증명은 기록하지 않고 개수·글자 수·언어 코드·오류 도메인/코드만 쓴다.
enum OnboardDiagnostics {
    struct Context: Sendable { let requestID: String; let batch: Int; let batches: Int }
    @TaskLocal static var context: Context?

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ScreenTranslator/onboard-performance.jsonl")
    private static let queue = DispatchQueue(label: "com.local.screentranslator.onboard-diagnostics")
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    static func newRequestID() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds) * 1000 + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    static func errorFields(_ error: Error) -> [String: Any] {
        let ns = error as NSError
        return ["errorDomain": ns.domain, "errorCode": ns.code]
    }

    /// 이벤트마다 열어서 덧붙이고 닫는다(append 후 즉시 flush).
    static func record(_ event: String, _ fields: [String: Any]) {
        var line = fields
        line["event"] = event
        line["pid"] = Int(ProcessInfo.processInfo.processIdentifier)
        line["app"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        queue.async {
            line["ts"] = formatter.string(from: Date())
            guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
            let manager = FileManager.default
            try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !manager.fileExists(atPath: fileURL.path) { manager.createFile(atPath: fileURL.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data([0x0A]))
            try? handle.synchronize()
        }
    }
}

/// 설치된 언어 팩만 쓰는 TranslationSession(installedSource:target:)을 언어 조합마다 재사용한다. 화면(UI)이 필요 없어
/// 앱이 화면 번역 창을 띄우지 않은 채로, 또 Safari 확장 안에서도 동작한다. 언어 팩이 없으면 내려받기 창을
/// 숨은 채로 띄우지 않고 실행 가능한 안내 오류를 낸다. 같은 세션에 동시에 요청하지 않도록 조합마다 차례로 처리한다.
@available(macOS 26.0, *)
actor BrowserDirectTranslator: BrowserTextTranslating {
    private static let maxSessions = 6
    private var sessions: [String: TranslationSession] = [:]
    private var sessionOrder: [String] = []
    /// 진단 전용: 언어 조합별로 마지막에 만든 세션의 전략과 선택 사유
    private var sessionInfo: [String: (strategy: String, reason: String)] = [:]
    private var busyKeys: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func supportedLanguageIDs() async -> [String] {
        await makeAvailability().supportedLanguages.map(\.minimalIdentifier)
    }

    func translate(_ texts: [String], source: String, target: String) async throws -> [String?] {
        try await translate(texts, source: source, target: target, partial: nil)
    }

    /// 부분 전달: 같은 요청 배열을 translate(batch:)로 보내 한 항목씩 끝나는 대로 알린다(묶음 크기·세션 전략은 그대로).
    private func collect(_ session: TranslationSession, _ requests: [TranslationSession.Request], partial: BrowserPartialHandler?,
                         started: ContinuousClock.Instant, stats: inout (firstMs: Int?, count: Int)) async throws -> [TranslationSession.Response] {
        guard let partial else { return try await session.translations(from: requests) }
        var responses: [TranslationSession.Response] = []
        for try await response in session.translate(batch: requests) {
            try Task.checkCancellation()
            responses.append(response)
            guard let identifier = response.clientIdentifier, let index = Int(identifier), requests.indices.contains(index) else { continue }
            if stats.firstMs == nil { stats.firstMs = OnboardDiagnostics.milliseconds(ContinuousClock.now - started) }
            stats.count += 1
            partial([(index, response.targetText)])
        }
        return responses
    }

    func translate(_ texts: [String], source: String, target: String, partial: BrowserPartialHandler?) async throws -> [String?] {
        let key = "\(source)>\(target)"
        let clock = ContinuousClock()
        let queueStart = clock.now
        await acquire(key)
        let queueDuration = clock.now - queueStart
        defer { release(key) }
        try Task.checkCancellation()
        var diagnostic: [String: Any] = [
            "request": OnboardDiagnostics.context?.requestID ?? "none", "batch": OnboardDiagnostics.context?.batch ?? -1,
            "batches": OnboardDiagnostics.context?.batches ?? -1, "source": source, "target": target, "items": texts.count,
            "utf16": texts.reduce(0) { $0 + $1.utf16.count }, "queueMs": OnboardDiagnostics.milliseconds(queueDuration),
            "sessionCacheHit": sessions[key] != nil, "outcome": "error"]
        let preparationStart = clock.now
        let session: TranslationSession
        let isFresh: Bool
        do {
            (session, isFresh) = try await self.session(for: key, source: source, target: target)
        } catch {
            diagnostic["outcome"] = "prepare_failed"
            diagnostic["prepareMs"] = OnboardDiagnostics.milliseconds(clock.now - preparationStart)
            diagnostic.merge(OnboardDiagnostics.errorFields(error)) { $1 }
            OnboardDiagnostics.record("onboard", diagnostic)
            throw error
        }
        let preparationDuration = clock.now - preparationStart
        let info = sessionInfo[key]
        diagnostic["strategy"] = info?.strategy ?? "unknown"
        diagnostic["strategyReason"] = info?.reason ?? "unknown"
        diagnostic["prepareMs"] = OnboardDiagnostics.milliseconds(preparationDuration)
        let translationStart = clock.now
        var partialStats: (firstMs: Int?, count: Int) = (nil, 0)
        defer {
            let translationDuration = clock.now - translationStart
            if partial != nil {
                diagnostic["streaming"] = true
                diagnostic["partials"] = partialStats.count
                if let first = partialStats.firstMs { diagnostic["firstPartialMs"] = first }
            }
            func milliseconds(_ duration: Duration) -> Int {
                Int(duration.components.seconds) * 1000 + Int(duration.components.attoseconds / 1_000_000_000_000_000)
            }
            diagnostic["inferenceMs"] = milliseconds(translationDuration)
            if Task.isCancelled, diagnostic["outcome"] as? String == "error" { diagnostic["outcome"] = "cancelled" }
            OnboardDiagnostics.record("onboard", diagnostic)
            // 처리 시간과 개수만 기록한다. 번역문·원문·언어·요청 식별자는 기록하지 않는다.
            Logger(subsystem: "com.local.screentranslator", category: "TranslationPerformance")
                .info("Onboard queue_ms=\(milliseconds(queueDuration), privacy: .public) preparation_ms=\(milliseconds(preparationDuration), privacy: .public) translation_ms=\(milliseconds(translationDuration), privacy: .public) items=\(texts.count, privacy: .public)")
        }
        let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        let responses: [TranslationSession.Response]
        do {
            if isFresh {
                try await session.prepareTranslation()
            }
            responses = try await collect(session, requests, partial: partial, started: translationStart, stats: &partialStats)
            diagnostic["outcome"] = "ok"
        } catch {
            diagnostic["firstAttemptFailed"] = true
            let firstFailure = OnboardDiagnostics.errorFields(error)
            diagnostic["firstErrorDomain"] = firstFailure["errorDomain"]
            diagnostic["firstErrorCode"] = firstFailure["errorCode"]
            // 세션이 망가졌을 수 있으므로 다음 요청에서 새로 만든다.
            dropSession(key)
            if TranslationError.notInstalled ~= error {
                try Task.checkCancellation()
                let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
                let subsequentStatus = await makeAvailability().status(from: from, to: to)
                let isInstalled = subsequentStatus == .installed
                let isContradictorySupported = subsequentStatus == .supported
                diagnostic["fastPackInstalled"] = isInstalled
                diagnostic["subsequentStatus"] = "\(subsequentStatus)"
                // 처음 세션을 얻을 때 이미 .installed 상태를 확인했으므로,
                // 번역 직후 일시적으로 .supported로 보고되는 모순 상태(contradictory installed->supported)에서도
                // 언어팩 누락으로 잘못 판단하지 않고 같은 전략(lowLatency)으로 1회 유계 복구를 시도한다.
                guard isInstalled || isContradictorySupported else {
                    diagnostic["outcome"] = subsequentStatus == .unsupported ? "unsupported_language" : "language_not_installed"
                    if subsequentStatus == .unsupported {
                        throw BrowserEngineError.unsupportedPair("\(source)→\(target)")
                    } else {
                        throw BrowserEngineError.languageNotInstalled("\(source)→\(target)")
                    }
                }
                diagnostic["retried"] = true
                diagnostic["contradictoryRecovery"] = isContradictorySupported
                let retry = self.createSession(for: key, from: from, to: to,
                                               reason: isContradictorySupported ? "macOS>=26.4, contradictory supported recovery" : "macOS>=26.4, retry installed")
                diagnostic["retryStrategy"] = sessionInfo[key]?.strategy ?? "unknown"
                do {
                    try await retry.prepareTranslation()
                    responses = try await collect(retry, requests, partial: partial, started: translationStart, stats: &partialStats)
                    diagnostic["outcome"] = "ok_after_retry"
                } catch {
                    dropSession(key)
                    diagnostic.merge(OnboardDiagnostics.errorFields(error)) { $1 }
                    try Task.checkCancellation()
                    if TranslationError.notInstalled ~= error {
                        diagnostic["outcome"] = "retry_not_installed"
                        throw BrowserEngineError.translationFailed("언어팩은 설치되어 있지만 번역 서비스가 응답하지 않습니다. 다시 번역하세요.")
                    }
                    if TranslationError.unsupportedLanguagePairing ~= error {
                        diagnostic["outcome"] = "unsupported_language"
                        throw BrowserEngineError.unsupportedPair("\(source)→\(target)")
                    }
                    diagnostic["outcome"] = "retry_failed"
                    throw error
                }
            } else {
                diagnostic.merge(OnboardDiagnostics.errorFields(error)) { $1 }
                diagnostic["outcome"] = "failed"
                if TranslationError.unsupportedLanguagePairing ~= error { throw BrowserEngineError.unsupportedPair("\(source)→\(target)") }
                throw error
            }
        }
        var output = [String?](repeating: nil, count: texts.count)
        for response in responses {
            guard let identifier = response.clientIdentifier, let index = Int(identifier), output.indices.contains(index) else { continue }
            output[index] = response.targetText
        }
        return output
    }

    private func session(for key: String, source: String, target: String) async throws -> (session: TranslationSession, isFresh: Bool) {
        if let session = sessions[key] { return (session, false) }
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        switch await makeAvailability().status(from: from, to: to) {
        case .installed: break
        case .supported: throw BrowserEngineError.languageNotInstalled("\(source)→\(target)")
        case .unsupported: throw BrowserEngineError.unsupportedPair("\(source)→\(target)")
        @unknown default: throw BrowserEngineError.unsupportedPair("\(source)→\(target)")
        }
        let reason: String
        if #available(macOS 26.4, *) { reason = "macOS>=26.4, installed" } else { reason = "macOS<26.4" }
        let session = createSession(for: key, from: from, to: to, reason: reason)
        return (session, true)
    }

    private func createSession(for key: String, from: Locale.Language, to: Locale.Language, reason: String) -> TranslationSession {
        let session: TranslationSession
        if #available(macOS 26.4, *) {
            session = TranslationSession(installedSource: from, target: to, preferredStrategy: .lowLatency)
            sessionInfo[key] = ("lowLatency", reason)
        } else {
            session = TranslationSession(installedSource: from, target: to)
            sessionInfo[key] = ("default", reason)
        }
        sessions[key] = session
        sessionOrder.removeAll { $0 == key }
        sessionOrder.append(key)
        while sessionOrder.count > Self.maxSessions, let oldest = sessionOrder.first, !busyKeys.contains(oldest) {
            dropSession(oldest)
        }
        return session
    }

    private func makeAvailability() -> LanguageAvailability {
        if #available(macOS 26.4, *) { return LanguageAvailability(preferredStrategy: .lowLatency) }
        return LanguageAvailability()
    }

    private func dropSession(_ key: String) {
        sessions[key] = nil
        sessionInfo[key] = nil
        sessionOrder.removeAll { $0 == key }
    }

    private func acquire(_ key: String) async {
        if !busyKeys.contains(key) {
            busyKeys.insert(key)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    private func release(_ key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[key] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            busyKeys.remove(key)
        }
    }
}
