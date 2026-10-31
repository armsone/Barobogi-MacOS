import SwiftUI

struct RegionEditorView: View {
    @Binding var region: ActivationRegion
    @State private var draggingVertex: RegionVertex?

    private let cornerRadius: CGFloat = 22
    private let editorInset: CGFloat = 14
    private let dragHitRadius: CGFloat = 52

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size

            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(nsColor: .controlBackgroundColor))
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.secondary.opacity(0.45), lineWidth: 2)

                activeRegionPath(in: size)
                    .fill(Color.green.opacity(0.48))
                activeRegionPath(in: size)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineJoin: .round))

                Text("터치하면 다시 작동")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())

                ForEach(RegionVertex.allCases, id: \.rawValue) { vertex in
                    handle(for: vertex, in: size)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .coordinateSpace(name: "regionEditor")
            .contentShape(Rectangle())
            .gesture(editorDragGesture(in: size))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("트랙패드 활성화 영역 편집기")
        }
        .aspectRatio(1.6, contentMode: .fit)
    }

    private func activeRegionPath(in size: CGSize) -> Path {
        var path = Path()
        let points = region.points.map { displayPoint($0, in: size) }
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    private func handle(for vertex: RegionVertex, in size: CGSize) -> some View {
        let point = displayPoint(region.point(for: vertex), in: size)
        return Circle()
            .fill(Color.green)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .frame(width: 20, height: 20)
            .position(point)
            .accessibilityLabel(accessibilityName(for: vertex))
            .accessibilityHint("드래그하여 꼭짓점 위치를 변경합니다")
    }

    private func editorDragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("regionEditor"))
            .onChanged { value in
                if draggingVertex == nil {
                    draggingVertex = nearestVertex(to: value.startLocation, in: size)
                }
                guard let draggingVertex else { return }
                region = region.updating(draggingVertex, to: normalizedPoint(value.location, in: size))
            }
            .onEnded { _ in
                draggingVertex = nil
            }
    }

    private func nearestVertex(to location: CGPoint, in size: CGSize) -> RegionVertex? {
        RegionVertex.allCases
            .map { vertex in
                let point = displayPoint(region.point(for: vertex), in: size)
                return (vertex, hypot(point.x - location.x, point.y - location.y))
            }
            .filter { $0.1 <= dragHitRadius }
            .min { $0.1 < $1.1 }?
            .0
    }

    private func displayPoint(_ point: NormalizedPoint, in size: CGSize) -> CGPoint {
        let drawableWidth = max(1, size.width - editorInset * 2)
        let drawableHeight = max(1, size.height - editorInset * 2)
        return CGPoint(
            x: editorInset + point.x * drawableWidth,
            y: editorInset + (1 - point.y) * drawableHeight
        )
    }

    private func normalizedPoint(_ point: CGPoint, in size: CGSize) -> NormalizedPoint {
        let drawableWidth = max(1, size.width - editorInset * 2)
        let drawableHeight = max(1, size.height - editorInset * 2)
        return .init(
            x: (point.x - editorInset) / drawableWidth,
            y: 1 - (point.y - editorInset) / drawableHeight
        ).clamped()
    }

    private func accessibilityName(for vertex: RegionVertex) -> String {
        switch vertex {
        case .bottomLeft: "왼쪽 아래 꼭짓점"
        case .bottomRight: "오른쪽 아래 꼭짓점"
        case .topRight: "오른쪽 위 꼭짓점"
        case .topLeft: "왼쪽 위 꼭짓점"
        }
    }
}
