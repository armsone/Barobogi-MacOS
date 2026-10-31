import Foundation

/// 명령줄 문자열만으로 개발 관련 프로세스를 분류한다.
/// 결정적 규칙 기반이며, 매칭 순서가 우선순위다(구체적인 것 먼저).
public enum ProcessClassifier {

    /// 명령줄에서 개발 프로세스 종류를 판정한다. 해당 없으면 nil.
    public static func classify(command: String) -> DevProcessKind? {
        let lower = command.lowercased()

        // Gradle: 데몬/래퍼 (java 프로세스로 떠도 GradleDaemon으로 식별 가능)
        if lower.contains("gradledaemon") || lower.contains("gradle-launcher")
            || lower.contains("org.gradle") || lower.contains("gradlew") {
            return .gradle
        }
        // Kotlin 컴파일 데몬
        if lower.contains("kotlincompiledaemon") || lower.contains("kotlin-daemon")
            || lower.contains("org.jetbrains.kotlin.daemon") {
            return .kotlin
        }
        // 테스트 러너 (java/node보다 먼저 판정)
        if lower.contains("xctest") || lower.contains("jest-worker")
            || lower.contains("pytest") || lower.contains("junit")
            || lower.contains("vitest") {
            return .test
        }
        // 브라우저 자동화
        if lower.contains("chromedriver") || lower.contains("geckodriver")
            || lower.contains("playwright") || lower.contains("puppeteer")
            || lower.contains("selenium") || lower.contains("safaridriver")
            || lower.contains("--remote-debugging-port") {
            return .browserAutomation
        }
        // Android 에뮬레이터 / ADB
        if lower.contains("qemu-system") || lower.contains("emulator64")
            || lower.contains("/emulator/") || hasExecutable(lower, named: "emulator") {
            return .emulator
        }
        if hasExecutable(lower, named: "adb") {
            return .adb
        }
        // iOS 시뮬레이터
        if lower.contains("coresimulatorservice") {
            return nil
        }
        if lower.contains("simulator.app") || lower.contains("launchd_sim")
            || lower.contains("simctl") {
            return .simulator
        }
        // Xcode 빌드 도구
        if lower.contains("xcodebuild") || lower.contains("xcbbuildservice")
            || lower.contains("sourcekit-lsp") || lower.contains("swift-build")
            || lower.contains("swift-frontend") {
            return .xcode
        }
        // 로컬 개발 서버 (node 일반 매칭보다 먼저)
        if lower.contains("webpack-dev-server") || containsExecutableToken(lower, named: "vite")
            || lower.contains("next dev") || lower.contains("nodemon")
            || lower.contains("live-server") || lower.contains("http-server")
            || lower.contains("manage.py runserver") || lower.contains("rails server")
            || lower.contains("flask run") {
            return .localServer
        }
        // Node.js 일반
        if hasExecutable(lower, named: "node") || hasExecutable(lower, named: "npm")
            || hasExecutable(lower, named: "yarn") || hasExecutable(lower, named: "pnpm") {
            return .node
        }
        // Java 일반 (위의 구체 분류에 안 걸린 JVM)
        if hasExecutable(lower, named: "java") || lower.contains("/bin/java ") {
            return .java
        }
        return nil
    }

    /// 프로세스 목록을 분류하고 launchd 재부착 여부(관측 사실)를 함께 기록한다.
    /// "고아"라고 단정하지 않는다 — 세션 근거가 없기 때문이다.
    public static func classifyAll(_ processes: [ProcessSnapshot]) -> [ClassifiedProcess] {
        processes.compactMap { snapshot in
            guard let kind = classify(command: snapshot.command) else { return nil }
            return ClassifiedProcess(
                snapshot: snapshot,
                kind: kind,
                isReparentedToLaunchd: snapshot.ppid == 1
            )
        }
    }

    /// 명령줄 첫 토큰의 실행 파일 이름이 name과 일치하는지 확인한다.
    /// "node"가 "nodejs-docs.txt" 같은 인자에 오탐하지 않게 한다.
    private static func hasExecutable(_ lowercasedCommand: String, named name: String) -> Bool {
        guard let firstToken = lowercasedCommand.split(separator: " ").first else { return false }
        let executable = firstToken.split(separator: "/").last.map(String.init) ?? String(firstToken)
        return executable == name
    }

    private static func containsExecutableToken(_ lowercasedCommand: String, named name: String) -> Bool {
        lowercasedCommand.split(whereSeparator: \.isWhitespace).contains { token in
            token.split(separator: "/").last.map(String.init) == name
        }
    }
}
