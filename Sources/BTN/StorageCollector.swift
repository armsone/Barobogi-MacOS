import Foundation

/// 개발 도구 저장 공간을 읽기 전용으로 측정한다. 삭제나 시뮬레이터 제어는 하지 않는다.
enum StorageCollector {
    static func collect() -> StorageSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let simulatorRoot = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
        let derivedDataRoot = home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        let xctestDeviceRoot = home.appendingPathComponent("Library/Developer/XCTestDevices", isDirectory: true)

        let volume = volumeCapacity(at: home)
        let devices = simulatorDevices(at: simulatorRoot)
        return StorageSnapshot(
            volumeTotalBytes: volume.total,
            volumeAvailableBytes: volume.available,
            simulatorDeviceCount: devices.count,
            ephemeralSimulatorCount: devices.ephemeralCount,
            simulatorBytes: directoryBytes(at: simulatorRoot),
            derivedDataBytes: directoryBytes(at: derivedDataRoot),
            xctestDeviceBytes: directoryBytes(at: xctestDeviceRoot)
        )
    }

    private static func volumeCapacity(at url: URL) -> (total: UInt64, available: UInt64) {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]) else { return (0, 0) }
        return (
            UInt64(max(0, values.volumeTotalCapacity ?? 0)),
            UInt64(max(0, values.volumeAvailableCapacityForImportantUsage
                       ?? Int64(values.volumeAvailableCapacity ?? 0)))
        )
    }

    private static func simulatorDevices(at root: URL) -> (count: Int, ephemeralCount: Int) {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }

        var count = 0
        var ephemeralCount = 0
        for directory in directories {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let plistURL = directory.appendingPathComponent("device.plist")
            guard let data = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let values = plist as? [String: Any],
                  (values["isDeleted"] as? Bool) != true else { continue }
            count += 1
            let name = (values["name"] as? String)?.lowercased() ?? ""
            if (values["isEphemeral"] as? Bool) == true || name.contains("clone") || name.contains("복제") {
                ephemeralCount += 1
            }
        }
        return (count, ephemeralCount)
    }

    /// `du`는 디렉터리의 실제 재귀 사용량을 한 번에 계산한다. 실패하면 0으로 안전하게 폴백한다.
    private static func directoryBytes(at url: URL) -> UInt64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        guard let result = ReadOnlyCommand.run(
            executable: "/usr/bin/du",
            arguments: ["-sk", url.path],
            timeout: 60
        ), result.status == 0,
              let output = String(data: result.data, encoding: .utf8),
              let kilobytes = UInt64(output.split(whereSeparator: \.isWhitespace).first ?? "") else { return 0 }
        return kilobytes * 1024
    }
}
