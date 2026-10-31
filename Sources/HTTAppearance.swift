import AppKit
import SwiftUI

// MARK: - 병기스타일 테마 (Byungki-Style Themes)

/// 병기스타일 공통 5개 테마 선택지 ID (고정 순서: auto -> light -> friday -> jarvis -> ultron -> auto)
public enum HTTTheme: String, CaseIterable, Identifiable {
    case auto = "auto"
    case light = "light"
    case friday = "friday"
    case jarvis = "jarvis"
    case ultron = "ultron"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "자동 (시스템 설정)"
        case .light: return "라이트"
        case .friday: return "프라이데이"
        case .jarvis: return "자비스"
        case .ultron: return "울트론"
        }
    }

    public var next: HTTTheme {
        switch self {
        case .auto: return .light
        case .light: return .friday
        case .friday: return .jarvis
        case .jarvis: return .ultron
        case .ultron: return .auto
        }
    }

    /// 저장값 마이그레이션 및 파싱
    public static func from(storedString: String?) -> HTTTheme {
        guard let stored = storedString?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty else {
            return .auto
        }
        if stored == "medium" { return .light }
        if stored == "dark" { return .jarvis }
        return HTTTheme(rawValue: stored) ?? .auto
    }
}

// MARK: - 병기스타일 테마 팔레트 (Palette Tokens)

public struct HTTThemePalette {
    public let bg: Color
    public let card: Color
    public let surface: Color
    public let surface2: Color
    public let text: Color
    public let text2: Color
    public let muted: Color
    public let border: Color
    public let border2: Color
    public let accent: Color
    public let accentStrong: Color
    public let accentSoft: Color
    public let onAccent: Color
    public let warn: Color
    public let warnSoft: Color
    public let warnInk: Color
    public let danger: Color
    public let dangerSoft: Color

    public static let light = HTTThemePalette(
        bg: Color(hex: "#f5f4f0"),
        card: Color(hex: "#fbfaf7"),
        surface: Color(hex: "#ffffff"),
        surface2: Color(hex: "#ecebe4"),
        text: Color(hex: "#1f211c"),
        text2: Color(hex: "#4a4c44"),
        muted: Color(hex: "#666860"),
        border: Color(hex: "#e2dfd5"),
        border2: Color(hex: "#d0cdc0"),
        accent: Color(hex: "#5c6b3c"),
        accentStrong: Color(hex: "#46532c"),
        accentSoft: Color(hex: "#e8ebdb"),
        onAccent: Color(hex: "#ffffff"),
        warn: Color(hex: "#9c5415"),
        warnSoft: Color(hex: "#f7e9d8"),
        warnInk: Color(hex: "#6d3c10"),
        danger: Color(hex: "#9c3b2a"),
        dangerSoft: Color(hex: "#f6e3de")
    )

    public static let friday = HTTThemePalette(
        bg: Color(hex: "#f7efe3"),
        card: Color(hex: "#fffaf1"),
        surface: Color(hex: "#fffdf8"),
        surface2: Color(hex: "#f0e2cc"),
        text: Color(hex: "#2a1f16"),
        text2: Color(hex: "#55422f"),
        muted: Color(hex: "#725b45"),
        border: Color(hex: "#e8d8c0"),
        border2: Color(hex: "#d3bb98"),
        accent: Color(hex: "#9a4a12"),
        accentStrong: Color(hex: "#743508"),
        accentSoft: Color(hex: "#f6dfc0"),
        onAccent: Color(hex: "#ffffff"),
        warn: Color(hex: "#8a5a00"),
        warnSoft: Color(hex: "#f8e6b8"),
        warnInk: Color(hex: "#6d3c10"),
        danger: Color(hex: "#a3204a"),
        dangerSoft: Color(hex: "#f8dce4")
    )

    public static let jarvis = HTTThemePalette(
        bg: Color(hex: "#0c1420"),
        card: Color(hex: "#121c2b"),
        surface: Color(hex: "#162337"),
        surface2: Color(hex: "#1c2d44"),
        text: Color(hex: "#e3edf7"),
        text2: Color(hex: "#b3c4d6"),
        muted: Color(hex: "#8da2b8"),
        border: Color(hex: "#20324a"),
        border2: Color(hex: "#2d4663"),
        accent: Color(hex: "#4cc2e6"),
        accentStrong: Color(hex: "#8fdcf3"),
        accentSoft: Color(hex: "#12324a"),
        onAccent: Color(hex: "#04202b"),
        warn: Color(hex: "#f0b45c"),
        warnSoft: Color(hex: "#3a2d16"),
        warnInk: Color(hex: "#f4cf94"),
        danger: Color(hex: "#f28b82"),
        dangerSoft: Color(hex: "#3d2126")
    )

    public static let ultron = HTTThemePalette(
        bg: Color(hex: "#121316"),
        card: Color(hex: "#1a1c20"),
        surface: Color(hex: "#202328"),
        surface2: Color(hex: "#272a30"),
        text: Color(hex: "#e6e7ea"),
        text2: Color(hex: "#b8bbc2"),
        muted: Color(hex: "#8e929b"),
        border: Color(hex: "#2b2e34"),
        border2: Color(hex: "#3b3f47"),
        accent: Color(hex: "#f2566a"),
        accentStrong: Color(hex: "#ff8a95"),
        accentSoft: Color(hex: "#3a1a20"),
        onAccent: Color(hex: "#1a0508"),
        warn: Color(hex: "#e8a24f"),
        warnSoft: Color(hex: "#36291a"),
        warnInk: Color(hex: "#f2c27f"),
        danger: Color(hex: "#ff9a9a"),
        dangerSoft: Color(hex: "#3e1f22")
    )
}

// MARK: - 병기스타일 아이콘 스타일 (Icon Styles)

public enum HTTIconStyle: String, CaseIterable, Identifiable {
    case simple = "simple"
    case dimension = "dimension"
    case realistic = "realistic"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .simple: return "심플"
        case .dimension: return "입체"
        case .realistic: return "리얼"
        }
    }

    public var folderName: String {
        "\(rawValue)-design"
    }
}

// MARK: - 외관 저장소 (Appearance Store)

@MainActor
public final class HTTAppearanceStore: ObservableObject {
    public static let shared = HTTAppearanceStore()

    private let themeKey = "HTTThemeSelection"
    private let iconStyleKey = "HTTIconStyleSelection"

    @Published public var theme: HTTTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: themeKey)
        }
    }

    @Published public var iconStyle: HTTIconStyle {
        didSet {
            UserDefaults.standard.set(iconStyle.rawValue, forKey: iconStyleKey)
        }
    }

    private init() {
        // 첫 렌더링 전 동기적으로 설정 읽기 및 마이그레이션 수행
        let storedTheme = UserDefaults.standard.string(forKey: themeKey)
        let resolvedTheme = HTTTheme.from(storedString: storedTheme)
        self.theme = resolvedTheme
        if storedTheme != resolvedTheme.rawValue {
            UserDefaults.standard.set(resolvedTheme.rawValue, forKey: themeKey)
        }

        let storedIcon = UserDefaults.standard.string(forKey: iconStyleKey)
        if let storedIcon, let parsed = HTTIconStyle(rawValue: storedIcon) {
            self.iconStyle = parsed
        } else {
            self.iconStyle = .simple
            UserDefaults.standard.set(HTTIconStyle.simple.rawValue, forKey: iconStyleKey)
        }
    }

    public func palette(for systemColorScheme: ColorScheme) -> HTTThemePalette {
        switch theme {
        case .auto:
            let isDark: Bool
            if let appearance = NSApp?.effectiveAppearance ?? NSApplication.shared.effectiveAppearance as NSAppearance? {
                isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            } else {
                isDark = systemColorScheme == .dark
            }
            return isDark ? .jarvis : .light
        case .light:
            return .light
        case .friday:
            return .friday
        case .jarvis:
            return .jarvis
        case .ultron:
            return .ultron
        }
    }

    public func effectiveColorScheme(for systemColorScheme: ColorScheme) -> ColorScheme? {
        switch theme {
        case .auto:
            return nil
        case .light, .friday:
            return .light
        case .jarvis, .ultron:
            return .dark
        }
    }

    public func cycleTheme() {
        theme = theme.next
    }
}

// MARK: - 아이콘 로더 및 뷰 (HTTIconView)

public struct HTTIconView: View {
    public let id: String
    public var size: CGFloat = 20

    @ObservedObject private var store = HTTAppearanceStore.shared

    public init(id: String, size: CGFloat = 20) {
        self.id = id
        self.size = size
    }

    public var body: some View {
        Group {
            if let image = loadIconImage() {
                if store.iconStyle == .simple {
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                } else {
                    Image(nsImage: image)
                        .renderingMode(.original)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                }
            } else {
                fallbackSymbol
            }
        }
    }

    private func loadIconImage() -> NSImage? {
        let packFolder = store.iconStyle.folderName
        // 번들 내부 Resources/InterfaceIcons/<pack>-design/png/256/<id>.png
        let relativePath = "InterfaceIcons/\(packFolder)/png/256/\(id).png"

        var url: URL?
        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                url = candidate
            }
        }
        if url == nil {
            // 프로젝트 빌드 경로 및 리소스 탐색 대체
            let candidate = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(relativePath)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                url = candidate
            }
        }

        guard let targetURL = url, let image = NSImage(contentsOf: targetURL) else {
            return nil
        }

        if store.iconStyle == .simple {
            image.isTemplate = true
        }
        return image
    }

    @ViewBuilder
    private var fallbackSymbol: some View {
        let symbolName: String = {
            switch id {
            case "home": return "house.fill"
            case "browser": return "globe"
            case "edit": return "pencil"
            case "device_files": return "internaldrive.fill"
            case "settings": return "gearshape.fill"
            case "help": return "questionmark.circle.fill"
            case "shield": return "shield.fill"
            case "theme": return "paintpalette.fill"
            default: return "app.fill"
            }
        }()

        Image(systemName: symbolName)
            .font(.system(size: size * 0.9))
            .frame(width: size, height: size)
    }
}

// MARK: - 병기스타일 테마 아이콘 벡터 렌더러 (HTTThemeIconShape)

public struct HTTThemeIconView: View {
    public let theme: HTTTheme
    public var size: CGFloat = 20

    public init(theme: HTTTheme, size: CGFloat = 20) {
        self.theme = theme
        self.size = size
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 24.0
            var path = Path()

            switch theme {
            case .auto:
                let center = CGPoint(x: 12 * scale, y: 12 * scale)
                let radius = 8 * scale
                path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                context.stroke(path, with: .color(.primary), lineWidth: 1.7 * scale)

                var halfCircle = Path()
                halfCircle.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
                halfCircle.closeSubpath()
                context.fill(halfCircle, with: .color(.primary))

            case .light:
                let center = CGPoint(x: 12 * scale, y: 12 * scale)
                let r = 3.8 * scale
                path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                // Rays
                let rays: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                    (12, 3.5, 12, 5.7), (12, 18.3, 12, 20.5), (3.5, 12, 5.7, 12), (18.3, 12, 20.5, 12),
                    (6, 6, 7.6, 7.6), (16.4, 16.4, 18, 18), (6, 18, 7.6, 16.4), (16.4, 7.6, 18, 6)
                ]
                for ray in rays {
                    path.move(to: CGPoint(x: ray.0 * scale, y: ray.1 * scale))
                    path.addLine(to: CGPoint(x: ray.2 * scale, y: ray.3 * scale))
                }
                context.stroke(path, with: .color(.primary), lineWidth: 1.7 * scale)

            case .friday:
                path.move(to: CGPoint(x: 12 * scale, y: 3 * scale))
                path.addLine(to: CGPoint(x: 19.8 * scale, y: 7.5 * scale))
                path.addLine(to: CGPoint(x: 19.8 * scale, y: 16.5 * scale))
                path.addLine(to: CGPoint(x: 12 * scale, y: 21 * scale))
                path.addLine(to: CGPoint(x: 4.2 * scale, y: 16.5 * scale))
                path.addLine(to: CGPoint(x: 4.2 * scale, y: 7.5 * scale))
                path.closeSubpath()
                context.stroke(path, with: .color(.primary), lineWidth: 1.7 * scale)

                var innerCircle = Path()
                let center = CGPoint(x: 12 * scale, y: 12 * scale)
                innerCircle.addEllipse(in: CGRect(x: center.x - 3 * scale, y: center.y - 3 * scale, width: 6 * scale, height: 6 * scale))
                context.fill(innerCircle, with: .color(.primary))

            case .jarvis:
                let center = CGPoint(x: 12 * scale, y: 12 * scale)
                let r1 = 9 * scale
                path.addEllipse(in: CGRect(x: center.x - r1, y: center.y - r1, width: r1 * 2, height: r1 * 2))
                context.stroke(path, with: .color(.primary), style: StrokeStyle(lineWidth: 1.7 * scale, dash: [15.4 * scale, 3.45 * scale]))

                var innerCircle = Path()
                let r2 = 5 * scale
                innerCircle.addEllipse(in: CGRect(x: center.x - r2, y: center.y - r2, width: r2 * 2, height: r2 * 2))
                context.stroke(innerCircle, with: .color(.primary), lineWidth: 1.4 * scale)

                var dot = Path()
                let r3 = 1.7 * scale
                dot.addEllipse(in: CGRect(x: center.x - r3, y: center.y - r3, width: r3 * 2, height: r3 * 2))
                context.fill(dot, with: .color(.primary))

            case .ultron:
                path.move(to: CGPoint(x: 6 * scale, y: 4 * scale))
                path.addLine(to: CGPoint(x: 18 * scale, y: 4 * scale))
                path.addLine(to: CGPoint(x: 20.5 * scale, y: 9 * scale))
                path.addLine(to: CGPoint(x: 20.5 * scale, y: 15 * scale))
                path.addLine(to: CGPoint(x: 16.5 * scale, y: 20 * scale))
                path.addLine(to: CGPoint(x: 7.5 * scale, y: 20 * scale))
                path.addLine(to: CGPoint(x: 3.5 * scale, y: 15 * scale))
                path.addLine(to: CGPoint(x: 3.5 * scale, y: 9 * scale))
                path.closeSubpath()
                context.stroke(path, with: .color(.primary), lineWidth: 1.7 * scale)

                var mouth = Path()
                mouth.move(to: CGPoint(x: 9.5 * scale, y: 16.5 * scale))
                mouth.addLine(to: CGPoint(x: 14.5 * scale, y: 16.5 * scale))
                context.stroke(mouth, with: .color(.primary), lineWidth: 1.4 * scale)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 병기스타일 테마 전환 버튼 (HTTThemeButton)

public struct HTTThemeButton: View {
    @ObservedObject private var store = HTTAppearanceStore.shared
    @State private var showMenu = false
    @State private var longPressed = false

    public init() {}

    public var body: some View {
        Button {
            if !longPressed {
                store.cycleTheme()
            }
            longPressed = false
        } label: {
            HStack(spacing: 6) {
                HTTThemeIconView(theme: store.theme, size: 16)
                Text(store.theme.displayName)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    longPressed = true
                    showMenu = true
                }
        )
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("병기스타일 테마")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                Divider()
                ForEach(HTTTheme.allCases) { item in
                    Button {
                        store.theme = item
                        showMenu = false
                    } label: {
                        HStack {
                            HTTThemeIconView(theme: item, size: 14)
                            Text(item.displayName)
                            Spacer()
                            if store.theme == item {
                                Image(systemName: "checkmark")
                                    .font(.caption)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(width: 170)
        }
        .contextMenu {
            ForEach(HTTTheme.allCases) { item in
                Button {
                    store.theme = item
                } label: {
                    if store.theme == item {
                        Label(item.displayName, systemImage: "checkmark")
                    } else {
                        Text(item.displayName)
                    }
                }
            }
        }
        .accessibilityLabel("병기스타일 테마: \(store.theme.displayName) (누르면 \(store.theme.next.displayName), 길게 누르면 목록)")
    }
}

// MARK: - Color Hex 초기화 도우미

private extension Color {
    init(hex: String) {
        let cleanHex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleanHex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch cleanHex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: Double(a) / 255.0
        )
    }
}
