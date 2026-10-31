import SwiftUI

// 성공한 수동 변환('') 결과를 확인·수정·삭제하는 설정 항목. 목록은 이 Mac에만 저장된다.
@MainActor
struct PersonalDictionaryView: View {
    @ObservedObject private var store = PersonalDictionaryStore.shared
    @State private var showsSheet = false

    init() {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("학습된 변환 사전 (\(store.entries.count)개)")
                Spacer()
                Button("관리…") { showsSheet = true }
            }
            Text("'' 변환이 성공하면 원문과 결과가 이 Mac에만 저장되고, 다음부터 먼저 적용됩니다. 직접 고친 항목이 우선합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showsSheet) {
            PersonalDictionarySheet(store: store)
        }
    }
}

@MainActor
private struct PersonalDictionarySheet: View {
    @ObservedObject var store: PersonalDictionaryStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @State private var draft = ""

    private var sortedSources: [String] {
        store.entries.keys.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("학습된 변환 사전")
                .font(.headline)
            Text("성공한 '' 변환만 저장되며 입력 내용은 이 Mac 밖으로 보내지 않습니다. 바로 앞의 한 단어 기준으로만 적용됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.entries.isEmpty {
                Text("아직 학습된 단어가 없습니다.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(sortedSources, id: \.self, selection: $selection) { source in
                    HStack {
                        Text(source)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        Text(store.entries[source] ?? "")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 160)

                if let selected = selection, store.entries[selected] != nil {
                    PersonalDictionaryDetail(
                        source: selected, draft: $draft,
                        save: { store.set(source: selected, replacement: draft) },
                        delete: {
                            store.remove(source: selected)
                            selection = nil
                        }
                    )
                }
            }

            HStack {
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: selection) { newValue in
            draft = newValue.flatMap { store.entries[$0] } ?? ""
        }
    }
}

private struct PersonalDictionaryDetail: View {
    let source: String
    @Binding var draft: String
    let save: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("원문: \(source)")
            TextField("바꿀 텍스트", text: $draft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("저장", action: save)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("삭제", role: .destructive, action: delete)
            }
        }
    }
}
