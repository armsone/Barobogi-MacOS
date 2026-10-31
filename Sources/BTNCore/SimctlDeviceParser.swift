import Foundation

/// `xcrun simctl list devices -j` 출력을 파싱한다.
/// 관용적(tolerant) 파서: 모르는 필드는 무시하고, 형식이 어긋난 개별 기기는 조용히 건너뛴다.
/// 단, JSON 자체가 깨졌거나 devices 키가 없으면 nil을 반환해 "수집 실패"를 구분한다(fail closed).
public enum SimctlDeviceParser {

    /// JSON 데이터를 파싱해 런타임별 배열을 평탄화한 기기 목록을 반환한다.
    /// 반환 nil은 "출력 자체를 해석할 수 없음"을 뜻하며 빈 목록과 다르다.
    public static func parse(_ data: Data) -> [SimulatorDevice]? {
        guard
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let runtimes = root["devices"] as? [String: Any]
        else { return nil }

        var devices: [SimulatorDevice] = []
        // 런타임 키 정렬로 결정적 순서를 보장한다.
        for runtimeIdentifier in runtimes.keys.sorted() {
            guard let entries = runtimes[runtimeIdentifier] as? [Any] else { continue }
            for entry in entries {
                guard
                    let dict = entry as? [String: Any],
                    let device = parseDevice(dict, runtimeIdentifier: runtimeIdentifier)
                else { continue }
                devices.append(device)
            }
        }
        return devices
    }

    /// 문자열 편의 오버로드.
    public static func parse(_ json: String) -> [SimulatorDevice]? {
        parse(Data(json.utf8))
    }

    /// 기기 하나를 파싱한다. UDID가 유효한 UUID가 아니면 nil (필수 조건).
    static func parseDevice(_ dict: [String: Any], runtimeIdentifier: String) -> SimulatorDevice? {
        guard
            let udidString = dict["udid"] as? String,
            let udid = UUID(uuidString: udidString)
        else { return nil }

        let name = dict["name"] as? String ?? ""
        let state = SimulatorDeviceState(rawState: dict["state"] as? String ?? "")

        return SimulatorDevice(
            udid: udid,
            name: name,
            runtimeIdentifier: runtimeIdentifier,
            state: state,
            isAvailable: parseAvailability(dict),
            dataPath: dict["dataPath"] as? String,
            dataSizeBytes: parseUnsignedInteger(dict["dataPathSize"])
        )
    }

    private static func parseUnsignedInteger(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            let signed = number.int64Value
            return signed >= 0 ? UInt64(signed) : nil
        }
        if let string = value as? String {
            return UInt64(string)
        }
        return nil
    }

    /// 가용성 해석. 신형(isAvailable: Bool)과 구형(availability: "(available)") 형식을 모두 받아들이고,
    /// 어느 쪽도 없으면 nil(확인 불가)을 반환한다.
    static func parseAvailability(_ dict: [String: Any]) -> Bool? {
        if let flag = dict["isAvailable"] as? Bool {
            return flag
        }
        if let legacy = dict["availability"] as? String {
            if legacy.contains("unavailable") { return false }
            if legacy.contains("available") { return true }
        }
        if let error = dict["availabilityError"] as? String, !error.isEmpty {
            return false
        }
        return nil
    }
}
