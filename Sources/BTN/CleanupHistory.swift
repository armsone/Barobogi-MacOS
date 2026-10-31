import Foundation

struct CleanupImpactSummary: Sendable {
    let beforeMetrics: MetricsSnapshot
    let afterMetrics: MetricsSnapshot
    let beforeDiskAvailableBytes: UInt64?
    let afterDiskAvailableBytes: UInt64?
    let completedAt: Date
}

enum SystemImpactCollector {
    static func collect() -> (metrics: MetricsSnapshot, diskAvailableBytes: UInt64?) {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        let diskBytes = values?.volumeAvailableCapacityForImportantUsage.flatMap { value in
            value >= 0 ? UInt64(value) : nil
        }
        return (MetricsCollector.collect(), diskBytes)
    }
}

struct CleanupAuditEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let category: String
    let target: String
    let status: CleanupExecutionStatus
    let message: String
}

final class CleanupAuditStore {
    static let httBundleDirectoryName = "com.local.screentranslator"
    static let btnSubdirectoryName = "BTN"
    static let historyFileName = "cleanup-history.json"

    static func httHistoryFileURL(applicationSupportDirectory: URL? = nil) -> URL {
        let applicationSupport = applicationSupportDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent(httBundleDirectoryName, isDirectory: true)
            .appendingPathComponent(btnSubdirectoryName, isDirectory: true)
            .appendingPathComponent(historyFileName)
    }

    private let fileURL: URL
    private let maximumEntries: Int

    init(
        fileURL: URL? = nil,
        maximumEntries: Int = 200,
        applicationSupportDirectory: URL? = nil
    ) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            // 원본 BTN/BackToNormal 이력 파일에 직접 쓰지 않도록 항상 HTT 전용 경로만 사용한다.
            self.fileURL = Self.httHistoryFileURL(applicationSupportDirectory: applicationSupportDirectory)
        }
        self.maximumEntries = max(1, maximumEntries)
    }

    func load() -> [CleanupAuditEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([CleanupAuditEntry].self, from: data)
        else { return [] }
        return Array(entries.suffix(maximumEntries))
    }

    @discardableResult
    func append(_ newEntries: [CleanupAuditEntry], to existing: [CleanupAuditEntry]) -> [CleanupAuditEntry] {
        guard !newEntries.isEmpty else { return existing }
        let merged = Array((existing + newEntries).suffix(maximumEntries))
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(merged)
            try data.write(to: fileURL, options: .atomic)
            return merged
        } catch {
            // 이력 저장 실패가 실제 정리 결과를 바꾸거나 재시도하게 만들면 안 된다.
            return existing
        }
    }
}

final class CleanupProtectionStore {
    static let protectionKey = "protectedCleanupCandidateIDs"

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = BTNPreferences.resolveHTTDefaults() ?? .standard,
        key: String = CleanupProtectionStore.protectionKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    func save(_ identifiers: Set<String>) {
        defaults.set(identifiers.sorted(), forKey: key)
    }
}
