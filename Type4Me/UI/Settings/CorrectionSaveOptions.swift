import SwiftUI

/// One choice vocabulary used by confirmation entry points. History lacks a
/// trustworthy bundle ID, so it must not manufacture an App-scoped memory.
struct CorrectionSaveOptions: View {
    @Binding var selection: CorrectionLearningScope
    var allowsAppScope = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker(L("记住方式", "Remember as"), selection: $selection) {
                Text(L("只记住正确名称", "Canonical word only")).tag(CorrectionLearningScope.hotwordOnly)
                if allowsAppScope {
                    Text(L("仅此应用的纠错参考", "Reference in this app")).tag(CorrectionLearningScope.softReference)
                }
                Text(L("各应用通用的纠错参考", "Reference across apps")).tag(CorrectionLearningScope.sharedReference)
                Text(L("始终全局替换（所有模式）", "Always replace globally (all modes)"))
                    .tag(CorrectionLearningScope.hotwordAndMapping)
            }
            Text(selection == .hotwordAndMapping
                 ? L("仅用于你明确要求的快捷展开。引用、路径中的命中也会替换。", "Use only for explicit quick expansions. Matches in quotes and paths are also replaced.")
                 : L("正确名称进入热词；纠错参考只参与智能感知，不强制改字，也不增加模型调用。", "Canonical names become hotwords; references guide Intelli Sense without forced edits or extra model calls."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum CorrectionSaveFeedback {
    static func failure(_ error: Error) -> String {
        if case CorrectionVocabularyError.rollbackFailed = error {
            return L("保存未完成，回退也未能全部完成。请先检查名称、参考和快捷展开，不要继续重试覆盖。", "Save failed and rollback was incomplete. Inspect names, references and snippets before retrying.")
        }
        return L("未能保存。参考只接受安全的词语；请检查输入和文件权限后重试。", "Could not save. References require safe terms; check the input and file permissions before retrying.")
    }
}
