import SwiftUI

/// HTT 설정 화면에 포함되는 Mac 관리(BTN) 설정 뷰.
/// 전달받은 `BTNIntegration` 인스턴스의 `@Published` 상태를 그대로 관찰하며 인스턴스를 중복 생성하지 않는다.
@MainActor
public struct BTNSettingsView: View {
    @ObservedObject private var integration: BTNIntegration

    public init(integration: BTNIntegration = .shared) {
        self.integration = integration
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                statusHeaderBox
                statusCalloutBox
                togglesBox
                actionsRow
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusHeaderBox: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: integration.statusSymbolName)
                    .font(.title2)
                    .foregroundStyle(integration.statusColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text("HTT — Mac 관리")
                        .font(.headline)
                    Text(integration.statusSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let refreshed = integration.lastRefreshed {
                        Text("마지막 확인: \(refreshed.formatted(date: .omitted, time: .standard))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(integration.modeBadgeTitle)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private var statusCalloutBox: some View {
        if let migrationMessage = integration.migrationFailureMessage {
            GroupBox {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("기존 데이터 확인 실패 — 안전을 위해 정리 기능 차단됨")
                            .font(.callout.bold())
                        Text(migrationMessage)
                            .font(.callout)
                        Text("기존 보호 목록과 이력이 안전하게 확인되기 전까지 정리를 실행하지 않습니다. 앱을 다시 실행해 주세요.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                .padding(4)
            }
        } else if integration.isStandaloneConflictActive {
            GroupBox {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("일시 중지됨 — 기존 BTN 앱 실행 중")
                            .font(.callout.bold())
                        Text("기존 BTN이 실행 중이어서 Mac 관리 작업을 일시 중지했습니다.")
                            .font(.callout)
                        Text("기존 BTN을 종료하면 HTT의 Mac 관리를 사용할 수 있습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } icon: {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.orange)
                }
                .padding(4)
            }
        } else if !integration.isManagementEnabled {
            GroupBox {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mac 관리가 꺼져 있습니다")
                            .font(.callout.bold())
                        Text("꺼진 상태에서는 시스템 지표 수집, 30초 자동 새로고침, 후보 스캔 및 정리가 전혀 실행되지 않습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } icon: {
                    Image(systemName: "power")
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }
        } else if !integration.isRuntimeActive {
            GroupBox {
                HStack(alignment: .center, spacing: 10) {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Mac 관리가 일시 중지되어 있습니다")
                                .font(.callout.bold())
                            Text("새 진단과 정리가 중지된 상태입니다. 다시 시작하면 선택한 설정대로 동작합니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "stop.circle")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("다시 시작") {
                        integration.startIfEnabled()
                    }
                }
                .padding(4)
            }
        } else if !integration.isCleanupEnabled {
            GroupBox {
                Label {
                    Text("관찰 전용 모드 — 시스템 상태와 개발 저장 공간 진단만 수행하며 실제 정리는 시작되지 않습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } icon: {
                    Image(systemName: "eye")
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }
        }
    }

    private var togglesBox: some View {
        GroupBox("동작 설정") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Mac 관리 사용", isOn: $integration.isManagementEnabled)
                    Text("시스템 부하, 메모리 압박, 개발 저장 공간(DerivedData·시뮬레이터 등) 진단을 활성화합니다. 신규 기본값은 꺼짐입니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 3) {
                    Toggle("30초 자동 새로고침", isOn: $integration.isAutoRefreshEnabled)
                    Text("Mac 관리가 실행 중일 때 30초마다 시스템 지표와 개발 프로세스 상태를 갱신합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 3) {
                    Toggle("정리 기능 사용", isOn: $integration.isCleanupEnabled)
                        .disabled(integration.hasMigrationError)
                    Text("신규 기본값은 꺼짐(관찰 전용)입니다. 켜더라도 저위험 휴지통 이동 외 시뮬레이터·프로세스 정리는 항상 개별 선택과 최종 확인 후에만 실행됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var actionsRow: some View {
        HStack {
            Button {
                integration.showDetailWindow()
            } label: {
                Label("Mac 관리 상세 창 열기…", systemImage: "list.bullet.rectangle")
            }
            Spacer()
        }
    }
}
