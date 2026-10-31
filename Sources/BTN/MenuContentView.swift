import SwiftUI
import AppKit

/// 메뉴 바 또는 요약 팝오버에서 바로 보이는 요약 화면.
struct MenuContentView: View {
    @ObservedObject var model: MonitorViewModel
    let showDetail: () -> Void
    var checkForUpdates: (() -> Void)? = nil
    var canCheckForUpdates: Bool = true
    var quitAction: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: model.statusSymbolName)
                    .foregroundStyle(model.statusColor)
                Text("상태: \(model.effectiveStatusLabel)")
                    .font(.headline)
                Spacer()
            }

            Text(model.effectiveKeyCause)
                .font(.subheadline)

            if let refreshed = model.lastRefreshed {
                Text("마지막 확인: \(refreshed.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text(model.modeSummaryNote)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    model.refresh()
                } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                }
                .disabled(!model.canRunMonitoring || model.isRefreshing)

                Button {
                    showDetail()
                } label: {
                    Label("상세 보기", systemImage: "list.bullet.rectangle")
                }

                Spacer()

                if let quitAction {
                    Button("종료") {
                        quitAction()
                    }
                }
            }

            if let checkForUpdates {
                Button("업데이트 확인…") {
                    checkForUpdates()
                }
                .disabled(!canCheckForUpdates)
                .font(.caption)
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}
