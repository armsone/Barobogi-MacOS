import Foundation

/// 휴지통 이동 대상을 허용 루트의 기존 직접 하위 디렉터리 하나로 제한한다.
public enum CleanupPathValidator {
    public static func validatedDirectChild(
        path: String,
        expectedObjectIdentifier: String?,
        allowedRoot: URL
    ) -> URL? {
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let root = allowedRoot.standardizedFileURL
        guard target.deletingLastPathComponent() == root else { return nil }
        guard let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else { return nil }
        guard target.resolvingSymlinksInPath().deletingLastPathComponent()
                == root.resolvingSymlinksInPath() else { return nil }
        guard let expectedObjectIdentifier,
              filesystemObjectIdentifier(at: target) == expectedObjectIdentifier
        else { return nil }
        return target
    }

    public static func filesystemObjectIdentifier(at url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return "\(device.uint64Value):\(inode.uint64Value)"
    }
}
