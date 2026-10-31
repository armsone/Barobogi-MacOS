import SwiftUI
#if canImport(Translation)
import Translation
#endif

// 시스템 설정에서 온디바이스 한국어-영어 번역 모델 다운로드 및 사전 준비를 제공하는 뷰.
// macOS 26+ .translationTask 및 prepareTranslation()을 사용하여 시스템 권한 및 다운로드를 처리한다.
struct TranslationPreparationView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            #if canImport(Translation)
            if #available(macOS 26.0, *) {
                TranslationPreparationContentView()
            } else {
                Text("일반 단어 온디바이스 번역 모델 다운로드는 macOS 26 이상에서 지원됩니다. 현재 시스템 버전에서는 확정 어휘 사전(서비스, 사과 등), 영어 월 이름(5월'' → May), 두벌식 오타 복원(tjqltm'' → 서비스) 및 인명 발음 표기가 즉시 동작합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #else
            Text("현재 빌드 환경에서는 번역 프레임워크를 사용할 수 없습니다. 기본 사전, 월 이름, 두벌식 복원 및 인명 발음 표기가 적용됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #endif
        }
    }
}

#if canImport(Translation)
@available(macOS 26.0, *)
private struct TranslationPreparationContentView: View {
    @State private var statusMessage: String?
    @State private var isPreparing = false
    @State private var translationConfig: TranslationSession.Configuration?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: prepareModel) {
                    Label("한국어-영어 온디바이스 번역 모델 준비", systemImage: "arrow.down.circle")
                }
                .disabled(isPreparing)

                if isPreparing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .translationTask(translationConfig) { session in
                do {
                    try await session.prepareTranslation()
                    await MainActor.run {
                        isPreparing = false
                        statusMessage = "번역 모델이 성공적으로 준비되었습니다."
                    }
                } catch {
                    await MainActor.run {
                        isPreparing = false
                        statusMessage = "번역 모델 준비 안내: \(error.localizedDescription)"
                    }
                }
            }

            if let message = statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message.contains("실패") ? .orange : .secondary)
            }

            Text("macOS 26 이상에서 온디바이스 번역 모델을 준비해 두면, 사과''→apple 처럼 한국어 단어 뒤에 ''를 입력했을 때, 또는 문장 끝에 \\\\(역슬래시 두 번)를 입력했을 때(문장 번역, 단어 사전에는 저장하지 않음) 시스템 내부에서 안전하게 번역할 수 있습니다. 영어 문장을 한국어로 옮기는 데는 영어-한국어 모델이 필요하며, 모델이 없으면 자동으로 내려받지 않고 원문을 그대로 둡니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func prepareModel() {
        isPreparing = true
        statusMessage = "번역 모델 상태를 확인하고 있습니다..."
        if translationConfig == nil {
            translationConfig = TranslationSession.Configuration(
                source: Locale.Language(identifier: "ko"),
                target: Locale.Language(identifier: "en")
            )
        } else {
            translationConfig?.invalidate()
        }
    }
}
#endif
