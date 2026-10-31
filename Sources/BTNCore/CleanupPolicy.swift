import Foundation

/// CleanupPolicy에 넘기는 관측값 묶음. 수집기가 채우고 결정 계층은 읽기만 한다.
/// nil은 "수집 실패/확인 불가"를 뜻하며, 해당 종류의 후보는 하나도 제안하지 않는다(fail closed).
public struct CleanupPolicyInput: Sendable, Equatable {
    /// simctl에서 파싱한 기기 목록. nil이면 시뮬레이터 후보를 제안하지 않는다.
    public var simulatorDevices: [SimulatorDevice]?
    /// device.plist에서 수집한 임시(clone) 증거. simctl 출력과는 UDID로만 병합한다.
    public var devicePlistEvidence: [SimulatorDevicePlistEvidence]
    /// DerivedData 하위 디렉터리 관측값. nil이면 DerivedData 후보를 제안하지 않는다.
    public var derivedDataEntries: [FilesystemCandidateEvidence]?
    /// XCTestDevices 하위 디렉터리 관측값. nil이면 XCTest 후보를 제안하지 않는다.
    public var xctestDeviceEntries: [FilesystemCandidateEvidence]?
    /// 분류된 개발 프로세스 목록. nil이면 빌드 활동 여부를 알 수 없으므로
    /// DerivedData 후보를 제안하지 않는다.
    public var devProcesses: [ClassifiedProcess]?
    /// 판단 기준 시각.
    public var now: Date

    public init(
        simulatorDevices: [SimulatorDevice]?,
        devicePlistEvidence: [SimulatorDevicePlistEvidence] = [],
        derivedDataEntries: [FilesystemCandidateEvidence]? = nil,
        xctestDeviceEntries: [FilesystemCandidateEvidence]? = nil,
        devProcesses: [ClassifiedProcess]? = nil,
        now: Date = Date()
    ) {
        self.simulatorDevices = simulatorDevices
        self.devicePlistEvidence = devicePlistEvidence
        self.derivedDataEntries = derivedDataEntries
        self.xctestDeviceEntries = xctestDeviceEntries
        self.devProcesses = devProcesses
        self.now = now
    }
}

/// 결정적 정리 정책. 같은 입력에는 항상 같은 후보 목록을 낸다.
/// 제안만 하며 삭제·종료 등 어떤 실행도 하지 않는다. 프로세스 종료 후보는 만들지 않는다.
public enum CleanupPolicy {

    /// 데이터 초기화 후보가 되는 시뮬레이터 데이터의 최소 크기 (512 MiB).
    /// 측정값이 이보다 작거나 없으면 초기화를 제안하지 않는다.
    public static let simulatorDataEraseMinimumBytes: UInt64 = 512 << 20
    /// DerivedData 개별 프로젝트의 최소 나이 (24시간).
    public static let derivedDataMinimumAgeSeconds: TimeInterval = 24 * 60 * 60
    /// XCTestDevices 디렉터리의 최소 나이 (7일).
    public static let xctestDeviceMinimumAgeSeconds: TimeInterval = 7 * 24 * 60 * 60

    /// DerivedData 최상위의 공유 캐시 디렉터리 이름 (소문자 비교). 개별 프로젝트가 아니므로 제외한다.
    public static let sharedDerivedDataNames: Set<String> = [
        "modulecache", "modulecache.noindex",
        "compilationcache", "compilationcache.noindex",
        "sdkstatcaches", "sdkstatcaches.noindex",
        "symbolcache", "symbolcache.noindex",
        "index.noindex", "info.plist",
    ]

    /// 관측값으로부터 정리 후보를 제안한다. 결과는 종류·식별자 순으로 정렬돼 결정적이다.
    public static func propose(_ input: CleanupPolicyInput) -> [CleanupCandidate] {
        var candidates: [CleanupCandidate] = []
        candidates.append(contentsOf: simulatorCandidates(input))
        candidates.append(contentsOf: derivedDataCandidates(input))
        candidates.append(contentsOf: xctestDeviceCandidates(input))
        return candidates.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.id < rhs.id
        }
    }

    // MARK: - 시뮬레이터

    private static func simulatorCandidates(_ input: CleanupPolicyInput) -> [CleanupCandidate] {
        guard let devices = input.simulatorDevices else { return [] }
        let evidenceByUDID = Dictionary(
            input.devicePlistEvidence.map { ($0.udid, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var result: [CleanupCandidate] = []
        for device in devices {
            // 규칙 1: 실행 중인 사용 가능 기기. 종료하면 메모리를 회수할 수 있고 데이터는 유지된다.
            if device.isAvailable == true, device.state == .booted {
                result.append(CleanupCandidate(
                    id: "sim-shutdown:\(device.udid.uuidString.lowercased())",
                    kind: .bootedSimulatorShutdown,
                    targetIdentifier: device.udid.uuidString,
                    targetPath: device.dataPath,
                    koreanReason: "실행 중인 시뮬레이터 '\(device.name)'입니다. 종료하면 사용 중인 앱과 테스트가 멈추지만 "
                        + "기기와 내부 데이터는 그대로 남고, 필요할 때 다시 실행할 수 있습니다.",
                    estimatedBytes: 0,
                    risk: .medium,
                    isRecoverable: true,
                    recoveryMethod: .restartable
                ))
                continue
            }

            // 규칙 2: 사용 불가 기기. isAvailable이 정확히 false이고 Shutdown 상태일 때만.
            if device.isAvailable == false, device.state == .shutdown {
                result.append(CleanupCandidate(
                    id: "sim-unavailable:\(device.udid.uuidString.lowercased())",
                    kind: .unavailableSimulatorDevice,
                    targetIdentifier: device.udid.uuidString,
                    targetPath: device.dataPath,
                    koreanReason: "현재 런타임이 없어 사용할 수 없는 시뮬레이터 '\(device.name)'입니다. "
                        + "런타임을 다시 설치하면 사용할 수 있는 기기일 수 있으며, 삭제하면 내부 데이터는 복구할 수 없습니다.",
                    estimatedBytes: device.dataSizeBytes ?? 0,
                    risk: .high,
                    isRecoverable: false,
                    recoveryMethod: .notRecoverable
                ))
                continue
            }

            // 나머지 규칙은 모두 현재 상태가 정확히 Shutdown이며 사용 가능(true)일 때만 적용된다.
            // Booted/Creating/Shutting Down/unknown 상태는 절대 후보가 아니다.
            guard device.state == .shutdown, device.isAvailable == true else { continue }

            // 규칙 3: 테스트용 임시(clone) 기기.
            // device.plist 증거(UDID 일치 + isEphemeral == true)가 있을 때만 삭제 후보가 된다.
            if let evidence = evidenceByUDID[device.udid], evidence.indicatesClone {
                result.append(CleanupCandidate(
                    id: "sim-clone:\(device.udid.uuidString.lowercased())",
                    kind: .ephemeralCloneSimulatorDevice,
                    targetIdentifier: device.udid.uuidString,
                    targetPath: device.dataPath,
                    koreanReason: "테스트가 만든 임시 복제 시뮬레이터 '\(device.name)'입니다. "
                        + "현재 종료 상태이며, 삭제해도 다음 테스트가 새로 만듭니다.",
                    estimatedBytes: device.dataSizeBytes ?? 0,
                    risk: .low,
                    isRecoverable: false,
                    recoveryMethod: .notRecoverable
                ))
                continue
            }

            // 규칙 4: 정상(비임시) 기기의 데이터 초기화 (simctl erase).
            // 기기 자체는 남기고 내부 데이터만 지운다. 측정된 크기가 최소 기준 이상일 때만 제안한다.
            guard
                let sizeBytes = device.dataSizeBytes,
                sizeBytes >= simulatorDataEraseMinimumBytes
            else { continue }

            result.append(CleanupCandidate(
                id: "sim-erase:\(device.udid.uuidString.lowercased())",
                kind: .simulatorDataErase,
                targetIdentifier: device.udid.uuidString,
                targetPath: device.dataPath,
                koreanReason: "시뮬레이터 '\(device.name)'의 앱·콘텐츠 데이터가 "
                    + "\(DiagnosticEngine.formatBytes(sizeBytes))를 차지하고 있습니다. "
                    + "초기화하면 이 데이터는 되돌릴 수 없이 지워지지만, "
                    + "시뮬레이터 기기 자체는 그대로 남아 바로 다시 사용할 수 있습니다.",
                estimatedBytes: sizeBytes,
                risk: .medium,
                isRecoverable: false,
                recoveryMethod: .recreatable
            ))
        }
        return result
    }

    // MARK: - DerivedData

    private static func derivedDataCandidates(_ input: CleanupPolicyInput) -> [CleanupCandidate] {
        guard let entries = input.derivedDataEntries else { return [] }
        // 빌드 활동 여부를 모르거나(nil) 빌드·테스트 프로세스가 살아 있으면 전부 제외.
        guard let processes = input.devProcesses else { return [] }
        guard !processes.contains(where: isActiveBuildOrTest) else { return [] }

        return entries.compactMap { entry in
            guard !sharedDerivedDataNames.contains(entry.name.lowercased()) else { return nil }
            guard let modifiedAt = entry.modifiedAt,
                  entry.filesystemObjectIdentifier != nil,
                  input.now.timeIntervalSince(modifiedAt) >= derivedDataMinimumAgeSeconds
            else { return nil }

            let ageDays = Int(input.now.timeIntervalSince(modifiedAt) / 86_400)
            let ageText = ageDays >= 1 ? "\(ageDays)일" : "24시간"
            return CleanupCandidate(
                id: "deriveddata:\(entry.name)",
                kind: .derivedDataProject,
                targetIdentifier: entry.name,
                targetPath: entry.path,
                koreanReason: "Xcode 빌드 산출물 '\(entry.name)'이(가) \(ageText) 이상 수정되지 않았습니다. "
                    + "삭제해도 다음 빌드 때 다시 만들어집니다.",
                estimatedBytes: entry.sizeBytes ?? 0,
                risk: .low,
                isRecoverable: true,
                recoveryMethod: .userTrash,
                filesystemObjectIdentifier: entry.filesystemObjectIdentifier
            )
        }
    }

    private static func isActiveBuildOrTest(_ process: ClassifiedProcess) -> Bool {
        if process.kind == .test { return true }
        guard process.kind == .xcode else { return false }
        let command = process.snapshot.command.lowercased()
        // 편집기 언어 서버(sourcekit-lsp)는 파일을 빌드하지 않으므로 제외한다.
        return command.contains("xcodebuild")
            || command.contains("xcbbuildservice")
            || command.contains("swift-build")
            || command.contains("swift-frontend")
    }

    // MARK: - XCTestDevices

    private static func xctestDeviceCandidates(_ input: CleanupPolicyInput) -> [CleanupCandidate] {
        guard let entries = input.xctestDeviceEntries else { return [] }

        return entries.compactMap { entry in
            // 나이 7일 이상 + 상태가 명시적으로 Shutdown일 때만. 상태를 모르면 제외.
            guard let modifiedAt = entry.modifiedAt,
                  entry.filesystemObjectIdentifier != nil,
                  input.now.timeIntervalSince(modifiedAt) >= xctestDeviceMinimumAgeSeconds,
                  entry.deviceState == .shutdown
            else { return nil }

            return CleanupCandidate(
                id: "xctest:\(entry.name)",
                kind: .xctestDeviceDirectory,
                targetIdentifier: entry.name,
                targetPath: entry.path,
                koreanReason: "XCTest용 기기 데이터 '\(entry.name)'이(가) 7일 이상 사용되지 않았고 "
                    + "종료 상태입니다. 삭제해도 다음 테스트가 새로 만듭니다.",
                estimatedBytes: entry.sizeBytes ?? 0,
                risk: .medium,
                isRecoverable: true,
                recoveryMethod: .userTrash,
                filesystemObjectIdentifier: entry.filesystemObjectIdentifier
            )
        }
    }
}

/// 실행 직전 재검증. 새 관측값으로 정책을 다시 돌려 같은 후보가 다시 나오는지 확인한다.
/// 안전 조건이 하나라도 달라졌으면(기기 부팅됨, 최근 수정됨, 증거 소실 등) 차단한다.
public enum CleanupRevalidation {

    /// 후보 하나를 새 관측값으로 재검증한다. 순수 함수이며 아무것도 실행하지 않는다.
    public static func revalidate(
        candidate: CleanupCandidate,
        against freshInput: CleanupPolicyInput
    ) -> CleanupRevalidationResult {
        let fresh = CleanupPolicy.propose(freshInput)
        guard let match = fresh.first(where: { $0.id == candidate.id }) else {
            return CleanupRevalidationResult(
                isAllowed: false,
                koreanReason: "최신 확인 결과 안전 조건이 더 이상 충족되지 않아 정리를 중단했습니다."
            )
        }
        guard match.kind == candidate.kind,
              match.targetIdentifier == candidate.targetIdentifier,
              match.targetPath == candidate.targetPath,
              match.filesystemObjectIdentifier == candidate.filesystemObjectIdentifier
        else {
            return CleanupRevalidationResult(
                isAllowed: false,
                koreanReason: "정리 대상이 처음 확인했을 때와 정확히 일치하지 않아 중단했습니다."
            )
        }
        return CleanupRevalidationResult(
            isAllowed: true,
            koreanReason: "최신 확인 결과 안전 조건이 그대로 유지되고 있습니다."
        )
    }

    /// 여러 후보를 한 번에 재검증한다. 결과 순서는 입력 순서와 같다.
    public static func revalidate(
        candidates: [CleanupCandidate],
        against freshInput: CleanupPolicyInput
    ) -> [(candidate: CleanupCandidate, result: CleanupRevalidationResult)] {
        candidates.map { ($0, revalidate(candidate: $0, against: freshInput)) }
    }
}
