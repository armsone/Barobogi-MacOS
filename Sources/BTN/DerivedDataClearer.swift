import Foundation

struct DerivedDataClearResult: Sendable, Equatable {
    let status: CleanupExecutionStatus
    let message: String
    let clearedCount: Int
}

/// DerivedData 루트의 직접 하위 항목만 휴지통으로 이동한다.
/// 루트 자체나 다른 Xcode 데이터는 건드리지 않으며, 폴더가 없거나 비어 있어도 완료로 취급한다(멱등).
enum DerivedDataClearer {
    static func clear(root: URL = CleanupEvidenceCollector.derivedDataRoot) -> DerivedDataClearResult {
        let fileManager = FileManager.default
        let standardizedRoot = root.standardizedFileURL

        guard fileManager.fileExists(atPath: standardizedRoot.path) else {
            return DerivedDataClearResult(
                status: .cleaned,
                message: "Derived Data 폴더가 없어 지울 항목이 없습니다.",
                clearedCount: 0
            )
        }

        guard let children = try? fileManager.contentsOfDirectory(
            at: standardizedRoot,
            includingPropertiesForKeys: nil
        ) else {
            return DerivedDataClearResult(
                status: .failed,
                message: "Derived Data 목록을 읽지 못해 아무것도 지우지 않았습니다.",
                clearedCount: 0
            )
        }

        guard !children.isEmpty else {
            return DerivedDataClearResult(
                status: .cleaned,
                message: "Derived Data가 이미 비어 있어 지울 항목이 없습니다.",
                clearedCount: 0
            )
        }

        var clearedCount = 0
        var firstErrorDescription: String?
        for child in children {
            // 나열 결과라도 이동 직전에 부모가 DerivedData 루트인지 다시 확인한다.
            let target = child.standardizedFileURL
            guard target.deletingLastPathComponent() == standardizedRoot else {
                firstErrorDescription = firstErrorDescription ?? "허용 범위 밖 경로를 건너뛰었습니다."
                continue
            }
            do {
                // 영구 삭제로 폴백하지 않는다.
                try fileManager.trashItem(at: target, resultingItemURL: nil)
                clearedCount += 1
            } catch {
                firstErrorDescription = firstErrorDescription ?? error.localizedDescription
            }
        }

        let failedCount = children.count - clearedCount
        guard failedCount == 0 else {
            let detail = firstErrorDescription.map { ": \($0)" } ?? ""
            return DerivedDataClearResult(
                status: .failed,
                message: "항목 \(children.count)개 중 \(failedCount)개를 휴지통으로 이동하지 못했습니다\(detail)",
                clearedCount: clearedCount
            )
        }
        return DerivedDataClearResult(
            status: .cleaned,
            message: "항목 \(clearedCount)개를 휴지통으로 이동했습니다. 필요하면 Finder의 휴지통에서 복원할 수 있습니다.",
            clearedCount: clearedCount
        )
    }
}
