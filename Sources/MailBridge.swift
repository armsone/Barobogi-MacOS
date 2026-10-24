import AppKit
import ApplicationServices
import Foundation

// 사용자가 버튼을 눌렀을 때만 Apple Mail의 "현재 선택된 메시지" 원본을 가져온다.
// 메시지를 보내거나 수정하지 않으며, 가져온 내용은 기록하지 않는다.

enum MailBridgeError: LocalizedError, Equatable {
    case mailNotRunning
    case notAuthorized
    case noSelection
    case emptySource
    case scriptFailed(code: Int)
    case messageNotFound
    case alreadyInTrash
    case identityUnavailable

    var errorDescription: String? {
        switch self {
        case .mailNotRunning:
            return "Mail 앱이 실행 중이 아닙니다. Mail을 열고 번역할 메시지를 선택한 뒤 다시 시도하세요."
        case .notAuthorized:
            return "Mail 접근이 허용되지 않았습니다. 시스템 설정 › 개인정보 보호 및 보안 › 자동화에서 '바로보기'의 Mail 항목에 허용이 필요합니다, 또는 '.eml 파일 열기'를 사용하세요. (이 앱은 보안 설정을 변경하지 않습니다.)"
        case .noSelection:
            return "Mail에서 선택된 메시지가 없습니다. 메시지 목록에서 메시지 하나를 선택하세요."
        case .emptySource:
            return "선택한 메시지의 원본을 가져오지 못했습니다. 메시지가 아직 다운로드되지 않았을 수 있습니다. '.eml 파일 열기'를 사용해 보세요."
        case .messageNotFound:
            return "Mail에서 이 메시지를 찾지 못했습니다. 이미 옮겨졌거나 삭제되었을 수 있어 아무것도 삭제하지 않았습니다."
        case .alreadyInTrash:
            return "이 메시지는 이미 휴지통에 있어 삭제하지 않았습니다."
        case .identityUnavailable:
            return "이 메시지를 Mail에서 정확히 식별할 수 없어 삭제하지 않았습니다."
        case .scriptFailed(let code):
            return "Mail에서 메시지를 가져오지 못했습니다(오류 \(code)). '.eml 파일 열기'로 대신 열 수 있습니다."
        }
    }
}

/// 번역한 바로 그 Mail 메시지를 가리키는 식별 정보(Mail 내부 id + Message-ID 헤더 + 계정/메일함 이름).
struct MailMessageRef: Equatable {
    let id: Int
    let messageIDHeader: String
    let accountID: String
    let account: String
    let mailbox: String
}

struct MailSelection {
    let source: String
    let selectionCount: Int
    let ref: MailMessageRef?
}

@MainActor
enum MailBridge {
    static let mailBundleID = "com.apple.mail"

    private static let scriptSource = """
    tell application id "com.apple.mail"
        set selectedMessages to selection
        set messageCount to count of selectedMessages
        if messageCount is 0 then return {"", 0}
        set theMessage to item 1 of selectedMessages
        set internalID to id of theMessage
        set headerID to ""
        set accountName to ""
        set accountIdentifier to ""
        set mailboxName to ""
        try
            set headerID to message id of theMessage
            set theMailbox to mailbox of theMessage
            set mailboxName to name of theMailbox
            set accountName to name of account of theMailbox
            set accountIdentifier to id of account of theMailbox
        end try
        return {source of theMessage, messageCount, internalID, headerID, accountName, mailboxName, accountIdentifier}
    end tell
    """

    /// com.apple.security.automation.apple-events 항목이 있어야 macOS가 이 확인을 처음 할 때
    /// 권한 요청 창을 띄운다(그래야 자동화 목록에 '바로보기'가 나타난다). 이미 결정된 뒤에는
    /// 즉시 결과만 돌려주며, 이 호출이 권한을 임의로 바꾸거나 설정을 여는 일은 없다.
    private static func automationPermissionStatus() -> OSStatus {
        var target = AEAddressDesc()
        let createStatus = mailBundleID.withCString { pointer in
            AECreateDesc(typeApplicationBundleID, pointer, mailBundleID.utf8.count, &target)
        }
        guard createStatus == noErr else { return OSStatus(createStatus) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, true)
    }

    static func fetchSelectedMessage() throws -> MailSelection {
        // Mail을 임의로 실행하지 않도록 실행 여부를 먼저 확인
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: mailBundleID).isEmpty else {
            throw MailBridgeError.mailNotRunning
        }
        let permission = automationPermissionStatus()
        switch permission {
        case noErr:
            break
        case OSStatus(procNotFound):
            throw MailBridgeError.mailNotRunning
        case -1743: // errAEEventNotPermitted: 실제 거부. 설정에서 직접 허용해야 한다.
            throw MailBridgeError.notAuthorized
        default:
            // 그 외 코드는 권한 거부로 단정하지 않고 원래 코드를 그대로 전달한다.
            throw MailBridgeError.scriptFailed(code: Int(permission))
        }
        guard let script = NSAppleScript(source: scriptSource) else {
            throw MailBridgeError.scriptFailed(code: -1)
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1
            switch code {
            case -1743, -10004: throw MailBridgeError.notAuthorized
            case -600, -609, -10810: throw MailBridgeError.mailNotRunning
            case -1728, -1719: throw MailBridgeError.noSelection
            default: throw MailBridgeError.scriptFailed(code: code)
            }
        }
        let count = Int(result.atIndex(2)?.int32Value ?? 0)
        guard count > 0 else { throw MailBridgeError.noSelection }
        guard let source = result.atIndex(1)?.stringValue, !source.isEmpty else {
            throw MailBridgeError.emptySource
        }
        var ref: MailMessageRef?
        if let internalID = result.atIndex(3)?.int32Value, internalID != 0,
           let header = result.atIndex(4)?.stringValue, !header.isEmpty,
           let account = result.atIndex(5)?.stringValue, !account.isEmpty,
           let mailbox = result.atIndex(6)?.stringValue, !mailbox.isEmpty,
           let accountID = result.atIndex(7)?.stringValue, !accountID.isEmpty {
            ref = MailMessageRef(id: Int(internalID), messageIDHeader: header,
                                 accountID: accountID, account: account, mailbox: mailbox)
        }
        return MailSelection(source: source, selectionCount: count, ref: ref)
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// 번역한 메시지 하나만 Mail의 휴지통 메일함으로 "이동"한다(delete는 사용자 설정에 따라 휴지통을 거치지 않을 수 있어 쓰지 않는다).
    /// 계정 id가 유일하게 일치하고, 이름이 같은 메일함이 하나뿐이며, 내부 id와 Message-ID가 모두 같고,
    /// 삭제 상태가 아닐 때만 실행한다. 하나라도 어긋나면 아무것도 하지 않는다. Mail 설정은 바꾸지 않는다.
    static func moveToTrash(_ ref: MailMessageRef) throws {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: mailBundleID).isEmpty else {
            throw MailBridgeError.mailNotRunning
        }
        guard !ref.messageIDHeader.isEmpty, !ref.accountID.isEmpty else {
            throw MailBridgeError.identityUnavailable
        }
        let source = """
        tell application id "com.apple.mail"
            set matchedAccounts to (every account whose id is \(quoted(ref.accountID)))
            if (count of matchedAccounts) is not 1 then return "ambiguous"
            set theAccount to item 1 of matchedAccounts
            set matchedBoxes to (every mailbox of theAccount whose name is \(quoted(ref.mailbox)))
            if (count of matchedBoxes) is not 1 then return "ambiguous"
            set theMailbox to item 1 of matchedBoxes
            set trashBox to trash mailbox
            try
                if (id of (account of trashBox)) is (id of theAccount) and (name of trashBox) is (name of theMailbox) then return "trash"
            end try
            set found to (every message of theMailbox whose id is \(ref.id))
            if (count of found) is not 1 then return "missing"
            set theMessage to item 1 of found
            if (message id of theMessage) is not \(quoted(ref.messageIDHeader)) then return "missing"
            if (deleted status of theMessage) is true then return "trash"
            move theMessage to trashBox
            return "ok"
        end tell
        """
        guard let script = NSAppleScript(source: source) else { throw MailBridgeError.scriptFailed(code: -1) }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1
            switch code {
            case -1743, -10004: throw MailBridgeError.notAuthorized
            case -600, -609, -10810: throw MailBridgeError.mailNotRunning
            case -1728, -1719: throw MailBridgeError.messageNotFound
            default: throw MailBridgeError.scriptFailed(code: code)
            }
        }
        switch result.stringValue {
        case "ok": return
        case "trash": throw MailBridgeError.alreadyInTrash
        case "ambiguous": throw MailBridgeError.identityUnavailable
        default: throw MailBridgeError.messageNotFound
        }
    }
}
