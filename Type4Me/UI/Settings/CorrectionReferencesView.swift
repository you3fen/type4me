import SwiftUI
import Type4MeIntelliSenseCore

/// One canonical-name view groups confirmed spellings without merging the files
/// or reinterpreting legacy quick expansions. Scope changes require a user action.
struct CorrectionReferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var references: [VocabularyCorrectionReference] = []
    @State private var edits: [String: String] = [:]
    @State private var errorMessage: String?

    private struct Group: Identifiable {
        let id: String
        let name: String
        let references: [VocabularyCorrectionReference]
    }
    private var groups: [Group] {
        Dictionary(grouping: references, by: { VocabularyTermIdentity.spellingKey($0.correctedText) })
            .map { Group(id: $0.key, name: $0.value[0].correctedText, references: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("名称与纠错参考", "Names and spelling references")).font(.title2)
            Text(L("修改名称会同步更新热词和对应参考，不修改快捷展开。共享需明确勾选，仍受敏感场景和歧义保护。",
                   "Renaming updates the hotword and its references, not quick expansions. Sharing is opt-in and still obeys privacy and ambiguity checks."))
                .font(.callout).foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
            }
            if references.isEmpty && errorMessage == nil {
                Text(L("尚无已确认的纠错参考", "No confirmed references yet"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.references) { reference in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(reference.wrongText).textSelection(.enabled)
                                        Text(reference.bundleIdentifier == "type4me:manual-confirmation"
                                             ? L("手动确认；原应用未知", "Manual confirmation; origin app unknown")
                                             : reference.bundleIdentifier)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Toggle(L("跨应用参考", "Share across apps"), isOn: Binding(
                                        get: { reference.sharedAcrossApps == true },
                                        set: { setSharing(reference, enabled: $0) }
                                    ))
                                    // A manual shared reference has no origin App to
                                    // restore. Remove it to revoke its use instead.
                                    .disabled(reference.bundleIdentifier == "type4me:manual-confirmation")
                                    .toggleStyle(.checkbox)
                                    Button(role: .destructive) { remove(reference) } label: {
                                        Image(systemName: "trash")
                                    }.help(L("仅移除此参考，保留名称", "Remove only this reference; keep the name"))
                                }.padding(.vertical, 4)
                            }
                        } header: {
                            HStack {
                                TextField(L("正确名称", "Canonical name"), text: Binding(
                                    get: { edits[group.id] ?? group.name },
                                    set: { edits[group.id] = $0 }
                                )).textFieldStyle(.roundedBorder)
                                Button(L("更新名称", "Rename")) { rename(group) }
                                    .disabled(edits[group.id] == nil || edits[group.id] == group.name)
                            }
                        }
                    }
                }
            }
            HStack {
                Button(L("刷新", "Refresh")) { reload() }
                Spacer()
                Button(L("完成", "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 720, height: 480)
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

    private func rename(_ group: Group) {
        do {
            _ = try CorrectionLearningStore().renameCanonical(group.name, to: edits[group.id] ?? group.name)
            edits[group.id] = nil
            reload()
        } catch { errorMessage = CorrectionSaveFeedback.failure(error) }
    }

    private func setSharing(_ reference: VocabularyCorrectionReference, enabled: Bool) {
        do {
            let current = try CorrectionReferenceStorage.load()
            let updated = current.map { old in
                guard old.id == reference.id else { return old }
                return VocabularyCorrectionReference(id: old.id, wrongText: old.wrongText,
                    correctedText: old.correctedText, bundleIdentifier: old.bundleIdentifier,
                    sourceRecordID: old.sourceRecordID, confirmedAt: old.confirmedAt,
                    sharedAcrossApps: enabled ? true : nil)
            }
            try CorrectionReferenceStorage.save(updated)
            reload()
        } catch { errorMessage = CorrectionSaveFeedback.failure(error) }
    }

    private func remove(_ reference: VocabularyCorrectionReference) {
        do {
            let current = try CorrectionReferenceStorage.load()
            try CorrectionReferenceStorage.save(current.filter { $0.id != reference.id })
            reload()
        } catch {
            errorMessage = L("删除失败，请重试。", "Could not remove the reference. Try again.")
        }
    }
}
