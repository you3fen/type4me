import SwiftUI

/// The save choice in the history correction sheet: add the correct spelling
/// to the hotwords, or also add an explicit replacement rule.
struct CorrectionSaveOptions: View {
    @Binding var selection: CorrectionLearningScope

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker(L("记住方式", "Remember as"), selection: $selection) {
                Text(L("加入热词", "Add as hotword")).tag(CorrectionLearningScope.hotwordOnly)
                Text(L("加入热词并始终替换（所有模式）", "Hotword and always replace (all modes)"))
                    .tag(CorrectionLearningScope.hotwordAndMapping)
            }
            Text(selection == .hotwordAndMapping
                 ? L("会同时新建一条替换规则。引用、路径中的命中也会被替换。", "Also creates a replacement rule. Matches in quotes and paths are replaced too.")
                 : L("正确写法进入热词：提升识别率，3 个字以上的中文词还会按口音容错自动纠正。", "The spelling becomes a hotword: it boosts recognition, and Chinese terms of three or more characters are also corrected with accent tolerance."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum CorrectionSaveFeedback {
    static func failure(_ error: Error) -> String {
        if case CorrectionVocabularyError.rollbackFailed = error {
            return L("保存未完成，回退也未能全部完成。请先检查热词和替换规则，不要继续重试覆盖。", "Save failed and rollback was incomplete. Inspect hotwords and replacement rules before retrying.")
        }
        return L("未能保存。请检查输入和文件权限后重试。", "Could not save. Check the input and file permissions before retrying.")
    }
}
