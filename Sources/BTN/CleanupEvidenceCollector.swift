import Foundation

/// 사용자가 요청할 때만 정리 근거를 읽는다. 수집 실패는 nil로 보존해 정책이 fail closed 하게 한다.
enum CleanupEvidenceCollector {
    static let simulatorRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
    static let derivedDataRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
    static let xctestDevicesRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer/XCTestDevices", isDirectory: true)

    static func collect(
        for kind: CleanupCandidateKind? = nil,
        measureSizes: Bool = true
    ) -> CleanupPolicyInput {
        let needsSimulator = kind == nil || kind?.targetsSimulator == true
        let needsDerivedData = kind == nil || kind == .derivedDataProject
        let needsXCTest = kind == nil || kind == .xctestDeviceDirectory

        var input = CleanupPolicyInput(
            simulatorDevices: needsSimulator ? simulatorDevices() : nil,
            devicePlistEvidence: needsSimulator ? simulatorPlistEvidence() : [],
            derivedDataEntries: needsDerivedData ? directoryEvidence(at: derivedDataRoot, includeState: false) : nil,
            xctestDeviceEntries: needsXCTest ? directoryEvidence(at: xctestDevicesRoot, includeState: true) : nil,
            devProcesses: needsDerivedData ? ProcessCollector.collectOptional().map(ProcessClassifier.classifyAll) : nil,
            now: Date()
        )

        // 파일 후보의 크기는 표시용이므로 정책 적용 후 필요한 경로만 제한적으로 측정한다.
        // 시뮬레이터 후보의 크기 조건은 simctl의 dataPathSize로 판정하므로 du로 다시 재지 않는다.
        guard measureSizes else { return input }
        let paths = Set(CleanupPolicy.propose(input).compactMap { candidate in
            candidate.kind.targetsSimulator ? nil : candidate.targetPath
        })
        guard !paths.isEmpty else { return input }
        let sizes = Dictionary(uniqueKeysWithValues: paths.map { ($0, directoryBytes(atPath: $0)) })
        input.derivedDataEntries = input.derivedDataEntries.map { entries in
            entries.map { entry in
                var updated = entry
                if let size = sizes[entry.path] { updated.sizeBytes = size }
                return updated
            }
        }
        input.xctestDeviceEntries = input.xctestDeviceEntries.map { entries in
            entries.map { entry in
                var updated = entry
                if let size = sizes[entry.path] { updated.sizeBytes = size }
                return updated
            }
        }
        return input
    }

    private static func simulatorDevices() -> [SimulatorDevice]? {
        guard let result = ReadOnlyCommand.run(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "list", "devices", "-j"],
            timeout: 20
        ), result.status == 0 else { return nil }
        return SimctlDeviceParser.parse(result.data)
    }

    private static func simulatorPlistEvidence() -> [SimulatorDevicePlistEvidence] {
        guard let directories = safeChildDirectories(at: simulatorRoot) else { return [] }
        return directories.compactMap { directory in
            guard let udid = UUID(uuidString: directory.lastPathComponent),
                  let values = readPlist(directory.appendingPathComponent("device.plist")),
                  (values["isDeleted"] as? Bool) != true else { return nil }
            let name = (values["name"] as? String)?.lowercased() ?? ""
            return SimulatorDevicePlistEvidence(
                udid: udid,
                isEphemeral: values["isEphemeral"] as? Bool,
                hasCloneNameMarker: name.range(
                    of: #"^clone [0-9]+ of "#,
                    options: .regularExpression
                ) != nil
            )
        }
    }

    private static func directoryEvidence(
        at root: URL,
        includeState: Bool
    ) -> [FilesystemCandidateEvidence]? {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let directories = safeChildDirectories(at: root) else { return nil }
        return directories.map { directory in
            let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey])
            let plist = includeState ? readPlist(directory.appendingPathComponent("device.plist")) : nil
            let state = (plist?["state"] as? String).map(SimulatorDeviceState.init(rawState:))
            return FilesystemCandidateEvidence(
                path: directory.standardizedFileURL.path,
                name: directory.lastPathComponent,
                modifiedAt: values?.contentModificationDate,
                sizeBytes: nil,
                deviceState: state,
                filesystemObjectIdentifier: CleanupPathValidator.filesystemObjectIdentifier(at: directory)
            )
        }
    }

    private static func safeChildDirectories(at root: URL) -> [URL]? {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return children.filter { child in
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }

    private static func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return object as? [String: Any]
    }

    private static func directoryBytes(atPath path: String) -> UInt64 {
        guard let result = ReadOnlyCommand.run(
            executable: "/usr/bin/du",
            arguments: ["-sk", path],
            timeout: 30
        ), result.status == 0,
              let output = String(data: result.data, encoding: .utf8),
              let kilobytes = UInt64(output.split(whereSeparator: \.isWhitespace).first ?? "")
        else { return 0 }
        return kilobytes * 1024
    }
}
