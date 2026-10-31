import Foundation

public enum RegionVertex: Int, CaseIterable, Sendable {
    case bottomLeft
    case bottomRight
    case topRight
    case topLeft
}

public struct ActivationRegion: Codable, Equatable, Sendable {
    public var bottomLeft: NormalizedPoint
    public var bottomRight: NormalizedPoint
    public var topRight: NormalizedPoint
    public var topLeft: NormalizedPoint

    public init(
        bottomLeft: NormalizedPoint,
        bottomRight: NormalizedPoint,
        topRight: NormalizedPoint,
        topLeft: NormalizedPoint
    ) {
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
        self.topRight = topRight
        self.topLeft = topLeft
    }

    /// 아래 양 모서리에서 상단 중앙으로 향하는 삼각형의 위쪽 1/3을 잘라낸 기본 영역입니다.
    public static let `default` = ActivationRegion(
        bottomLeft: .init(x: 0, y: 0),
        bottomRight: .init(x: 1, y: 0),
        topRight: .init(x: 2.0 / 3.0, y: 2.0 / 3.0),
        topLeft: .init(x: 1.0 / 3.0, y: 2.0 / 3.0)
    )

    public var points: [NormalizedPoint] {
        [bottomLeft, bottomRight, topRight, topLeft]
    }

    public func point(for vertex: RegionVertex) -> NormalizedPoint {
        switch vertex {
        case .bottomLeft: bottomLeft
        case .bottomRight: bottomRight
        case .topRight: topRight
        case .topLeft: topLeft
        }
    }

    public func updating(_ vertex: RegionVertex, to proposedPoint: NormalizedPoint) -> Self {
        var copy = self
        var point = proposedPoint.clamped()
        let gap = 0.04

        switch vertex {
        case .bottomLeft:
            point.x = min(point.x, bottomRight.x - gap)
            point.y = min(point.y, topLeft.y - gap)
            copy.bottomLeft = point
        case .bottomRight:
            point.x = max(point.x, bottomLeft.x + gap)
            point.y = min(point.y, topRight.y - gap)
            copy.bottomRight = point
        case .topRight:
            point.x = max(point.x, topLeft.x + gap)
            point.y = max(point.y, bottomRight.y + gap)
            copy.topRight = point
        case .topLeft:
            point.x = min(point.x, topRight.x - gap)
            point.y = max(point.y, bottomLeft.y + gap)
            copy.topLeft = point
        }
        return copy
    }

    public func contains(_ point: NormalizedPoint) -> Bool {
        let polygon = points
        guard polygon.count >= 3 else { return false }

        for index in polygon.indices {
            let start = polygon[index]
            let end = polygon[(index + 1) % polygon.count]
            if point.isOnSegment(from: start, to: end) {
                return true
            }
        }

        var inside = false
        var previousIndex = polygon.count - 1
        for index in polygon.indices {
            let current = polygon[index]
            let previous = polygon[previousIndex]
            let crossesY = (current.y > point.y) != (previous.y > point.y)
            if crossesY {
                let intersectionX = (previous.x - current.x) * (point.y - current.y)
                    / (previous.y - current.y) + current.x
                if point.x < intersectionX {
                    inside.toggle()
                }
            }
            previousIndex = index
        }
        return inside
    }
}

private extension NormalizedPoint {
    func isOnSegment(from start: NormalizedPoint, to end: NormalizedPoint) -> Bool {
        let cross = (y - start.y) * (end.x - start.x) - (x - start.x) * (end.y - start.y)
        guard abs(cross) < 0.000_001 else { return false }

        let dot = (x - start.x) * (end.x - start.x) + (y - start.y) * (end.y - start.y)
        guard dot >= 0 else { return false }

        let squaredLength = pow(end.x - start.x, 2) + pow(end.y - start.y, 2)
        return dot <= squaredLength
    }
}
