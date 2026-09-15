import SwiftUI
import Type4MeIntelliSenseCore

/// Local, user-confirmed references can always be inspected and removed.
/// Removing a reference never changes separately configured forced snippets.
struct CorrectionReferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var references: [VocabularyCorrectionReference] = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("已确认的纠错参考", "Confirmed spelling references")).font(.title2)
            Text(L("仅在同一应用的智能感知润色中提供参考，不强制替换。现有片段规则请在“片段替换”中管理。",
                   "References guide Intelli Sense in the same app; they are not forced replacements. Manage existing forced rules in Snippets."))
                .font(.callout).foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
            }
            if references.isEmpty && errorMessage == nil {
                Text(L("尚无已确认的纠错参考", "No confirmed references yet"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(references) { reference in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(reference.wrongText + " → " + reference.correctedText).textSelection(.enabled)
                            Text(reference.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { remove(reference) } label: {
                            Image(systemName: "trash")
                        }
                        .help(L("移除此参考", "Remove this reference"))
                    }
                    .padding(.vertical, 4)
                }
            }
            HStack {
                Button(L("刷新", "Refresh")) { reload() }
                Spacer()
                Button(L("完成", "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640, height: 460)
        .onAppear { reload() }
    }

    private func reload() {
        do {
            references = try CorrectionReferenceStorage.load()
            errorMessage = nil
        } catch {
            errorMessage = L("无法读取参考，原文件未改动。", "Could not read references. The original file was not changed.")
        }
    }

    private func remove(_ reference: VocabularyCorrectionReference) {
        do {
            // Reload to preserve references confirmed while this sheet was open.
            let current = try CorrectionReferenceStorage.load()
            try CorrectionReferenceStorage.save(current.filter { $0.id != reference.id })
            reload()
        } catch {
            errorMessage = L("删除失败，请重试。", "Could not remove the reference. Try again.")
        }
    }
}
