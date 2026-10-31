import Foundation

public struct AppInputLanguageRule: Codable, Identifiable, Equatable, Sendable {
    public var id: String { bundleID }
    public var bundleID: String
    public var displayName: String
    public var inputSourceID: String
    public var inputSourceName: String

    public init(
        bundleID: String,
        displayName: String,
        inputSourceID: String,
        inputSourceName: String
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.inputSourceID = inputSourceID
        self.inputSourceName = inputSourceName
    }
}

public struct InstalledInputSource: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { inputSourceID }
    public let inputSourceID: String
    public let localizedName: String

    public init(inputSourceID: String, localizedName: String) {
        self.inputSourceID = inputSourceID
        self.localizedName = localizedName
    }
}
