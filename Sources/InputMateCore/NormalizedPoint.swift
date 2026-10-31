import Foundation

public struct NormalizedPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func clamped() -> Self {
        .init(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}
