import Foundation

public enum IntelliSenseValidationWarning: String, Codable, Equatable, Sendable {
    case sourceProtectedTokenChanged
    case negationCountChanged
    case listStructureChanged
    case expectedListStructureMissing
    case largeRewrite
    case supersededContentRetained
    case contextTermAdopted
}

public enum IntelliSenseGuardRejection: String, Codable, Equatable, Sendable {
    case emptyOutput
    case protectedTokenChanged
    case negationChanged
    case responseMarkerChanged
    case answerOrExplanation
    case claimedExecution
    case codeFence
    case toolCall
    case extremeExpansion
    case languageChanged
    case sensitiveContentLeak
    case inventedProtectedFact
}

public enum IntelliSenseGuardDecision: Equatable, Sendable {
    case accept
    case acceptWithWarnings([IntelliSenseValidationWarning])
    case reject(IntelliSenseGuardRejection)
}

public struct IntelliSenseProcessingResult: Equatable, Sendable {
    public let candidateText: String
    public let finalText: String
    public let decision: IntelliSenseGuardDecision
    public let correctionAnalysis: CorrectionIntentAnalysis

    public init(
        candidateText: String,
        finalText: String,
        decision: IntelliSenseGuardDecision,
        correctionAnalysis: CorrectionIntentAnalysis
    ) {
        self.candidateText = candidateText
        self.finalText = finalText
        self.decision = decision
        self.correctionAnalysis = correctionAnalysis
    }
}

public enum IntelliSenseOutputValidator {
    public static func process(
        input: String,
        candidate: String,
        context: IntelliSenseContextSnapshot? = nil,
        vocabulary: [String] = []
    ) -> IntelliSenseProcessingResult {
        let analysis = CorrectionIntentAnalysis.analyze(input)
        let decision = evaluate(
            input: input, output: candidate, context: context, analysis: analysis, vocabulary: vocabulary
        )
        let final: String
        if case .reject = decision { final = input } else { final = candidate }
        return IntelliSenseProcessingResult(
            candidateText: candidate,
            finalText: final,
            decision: decision,
            correctionAnalysis: analysis
        )
    }

    public static func evaluate(
        input: String,
        output: String,
        context: IntelliSenseContextSnapshot? = nil,
        vocabulary: [String] = []
    ) -> IntelliSenseGuardDecision {
        process(input: input, candidate: output, context: context, vocabulary: vocabulary).decision
    }

    private static func evaluate(
        input: String,
        output: String,
        context: IntelliSenseContextSnapshot?,
        analysis: CorrectionIntentAnalysis,
        vocabulary: [String]
    ) -> IntelliSenseGuardDecision {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .reject(.emptyOutput) }
        guard !trimmed.contains("```") else { return .reject(.codeFence) }
        guard !looksLikeToolCall(trimmed) else { return .reject(.toolCall) }
        guard VocabularyLiteralProtection.preserved(input: input, candidate: trimmed) else {
            return .reject(.protectedTokenChanged)
        }
        guard !VocabularyLiteralProtection.deletesOnlyNegation(input: input, candidate: trimmed) else {
            return .reject(.negationChanged)
        }
        guard preservesLeadingResponseMarker(input: input, output: trimmed) else {
            return .reject(.responseMarkerChanged)
        }
        guard !looksLikeAnswerOrExplanation(input: input, output: trimmed) else {
            return .reject(.answerOrExplanation)
        }
        guard !claimsExecution(input: input, output: trimmed) else { return .reject(.claimedExecution) }

        for token in analysis.requiredProtectedTokens
        where ProtectedFactExtractor.isHardProtectedToken(token)
            && !contains(token: token, in: trimmed)
            && !joinsSpokenUnit(token, input: input, output: trimmed) {
            return .reject(.protectedTokenChanged)
        }
        let outputNegations = CorrectionIntentAnalysis.analyze(trimmed).semanticNegationCounts
        guard compatibleNegationRelations(analysis.semanticNegationCounts, outputNegations) else {
            return .reject(.negationChanged)
        }

        let inputCount = max(1, input.count)
        guard trimmed.count <= max(inputCount * 3, inputCount + 120) else {
            return .reject(.extremeExpansion)
        }
        guard !didChangePrimaryScript(input: input, output: trimmed) else {
            return .reject(.languageChanged)
        }
        guard !introducesSensitiveContent(input: input, output: trimmed) else {
            return .reject(.sensitiveContentLeak)
        }
        guard !inventsProtectedFact(input: input, output: trimmed, context: context, vocabulary: vocabulary) else {
            return .reject(.inventedProtectedFact)
        }

        var warnings: [IntelliSenseValidationWarning] = []
        if analysis.semanticNegationCounts != outputNegations {
            warnings.append(.negationCountChanged)
        }
        let inputTokens = ProtectedFactExtractor.tokens(in: input)
        if inputTokens != ProtectedFactExtractor.tokens(in: trimmed), analysis.supersededProtectedTokens.isEmpty {
            warnings.append(.sourceProtectedTokenChanged)
        }
        if listMarkerCount(in: trimmed) != listMarkerCount(in: input) {
            warnings.append(.listStructureChanged)
        }
        let structureIntent = ListStructureIntentAnalyzer.analyze(input)
        if ListStructureIntentAnalyzer.supportsStructuredOutput(context),
           let requiredItems = structureIntent.requiredItemCount,
           ListStructureIntentAnalyzer.listItemCount(in: trimmed) < requiredItems {
            warnings.append(.expectedListStructureMissing)
        }
        if abs(trimmed.count - input.count) > max(24, input.count / 2) {
            warnings.append(.largeRewrite)
        }
        if analysis.supersededProtectedTokens.contains(where: { contains(token: $0, in: trimmed) }) {
            warnings.append(.supersededContentRetained)
        }
        if let context, adoptedContextTerm(input: input, output: trimmed, context: context) {
            warnings.append(.contextTermAdopted)
        }
        return warnings.isEmpty ? .accept : .acceptWithWarnings(warnings)
    }

    /// A protected token must survive as itself: "99" inside "199" does not count.
    private static func contains(token: String, in text: String) -> Bool {
        let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: token) + "(?![A-Za-z0-9])"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// "4 K" written as "4K": the number survives, joined to the unit the speaker said.
    private static func joinsSpokenUnit(_ token: String, input: String, output: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        guard let spoken = try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9])" + escaped + #"\s+([A-Za-z]{1,3})(?![A-Za-z0-9])"#
        ) else { return false }
        return spoken.matches(in: input, range: NSRange(input.startIndex..., in: input)).contains { match in
            guard let unit = Range(match.range(at: 1), in: input) else { return false }
            return contains(token: token + input[unit], in: output)
        }
    }

    private static func compatibleNegationRelations(
        _ input: [String: Int],
        _ output: [String: Int]
    ) -> Bool {
        // During product evaluation, only strong prohibitions and emphatic
        // "never" relations justify discarding the entire polished result.
        // Other negation changes are observable warnings because valid
        // paraphrases frequently change their surface count.
        return input["prohibition", default: 0] == output["prohibition", default: 0]
            && input["never", default: 0] == output["never", default: 0]
    }

    private static func looksLikeAnswerOrExplanation(input: String, output: String) -> Bool {
        guard let outputPrefix = leadingAnswerPrefix(in: output) else { return false }
        return !sourceStartsWithAnswerPrefix(input, prefix: outputPrefix)
    }

    private static func sourceStartsWithAnswerPrefix(_ text: String, prefix: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.hasPrefix(prefix) else { return false }
        let isASCIIEnglishPrefix = prefix.unicodeScalars.allSatisfy { $0.value < 128 }
        guard isASCIIEnglishPrefix else { return true }
        let boundaryIndex = normalized.index(normalized.startIndex, offsetBy: prefix.count)
        guard boundaryIndex < normalized.endIndex else { return true }
        let next = normalized[boundaryIndex]
        return next.isWhitespace || "，,：:。.!！?？".contains(next)
    }

    private static func leadingAnswerPrefix(in text: String) -> String? {
        let prefixes = [
            "答案是", "回答", "当然可以", "好的", "以下是", "解释如下", "建议如下",
            "the answer is", "sure", "here is", "here's", "i recommend",
        ]
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return prefixes.first { prefix in
            guard normalized.hasPrefix(prefix) else { return false }
            let boundaryIndex = normalized.index(normalized.startIndex, offsetBy: prefix.count)
            guard boundaryIndex < normalized.endIndex else { return true }
            let next = normalized[boundaryIndex]
            return next.isWhitespace || "，,：:。.!！?？".contains(next)
        }
    }

    private static func preservesLeadingResponseMarker(input: String, output: String) -> Bool {
        guard let inputMarker = leadingResponseMarker(in: input) else { return true }
        return leadingResponseMarker(in: output) == inputMarker
    }

    private static func leadingResponseMarker(in text: String) -> String? {
        let markers = ["当然可以", "好的", "okay", "yes", "ok", "嗯", "哦", "好"]
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()
        for marker in markers where lower.hasPrefix(marker) {
            let boundaryIndex = lower.index(lower.startIndex, offsetBy: marker.count)
            guard boundaryIndex < lower.endIndex else { return marker }
            let next = lower[boundaryIndex]
            guard "，,：:。.!！?？".contains(next) else { continue }
            let remainder = lower[lower.index(after: boundaryIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let nonResponseContinuations = [
                "那个", "呃", "啊", "就是说", "你知道吧",
                "不对", "哦不", "改成", "换成", "应该是", "i mean", "sorry",
            ]
            guard !nonResponseContinuations.contains(where: remainder.hasPrefix) else {
                continue
            }
            return marker
        }
        return nil
    }

    private static func claimsExecution(input: String, output: String) -> Bool {
        let requestSignals = ["帮我", "请", "部署", "发送", "删除", "创建", "打开", "关闭"]
        guard requestSignals.contains(where: input.contains) else { return false }
        let claims = ["已经为你", "已为你", "操作完成", "部署完成", "发送成功", "删除成功", "创建成功", "done", "completed successfully"]
        let lower = output.lowercased()
        return claims.contains { lower.hasPrefix($0.lowercased()) }
    }

    private static func looksLikeToolCall(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("<tool_call")
            || lower.contains("\"tool_calls\"")
            || lower.hasPrefix("{\"name\":")
            || lower.hasPrefix("{\n  \"name\":")
    }

    private static func listMarkerCount(in text: String) -> Int {
        text.split(separator: "\n").filter { line in
            line.range(of: #"^\s*(?:[-*•]|\d+[.)、])\s*"#, options: .regularExpression) != nil
        }.count
    }

    private static func didChangePrimaryScript(input: String, output: String) -> Bool {
        let inputCounts = scriptCounts(input)
        let outputCounts = scriptCounts(output)
        // Mixed technical dictation can contain many Latin path/identifier
        // tokens while its surrounding sentence is still clearly Chinese.
        // Never allow that Chinese carrier sentence to disappear entirely.
        if inputCounts.cjk >= 4, outputCounts.cjk == 0 {
            return true
        }
        guard inputCounts.total >= 8, outputCounts.total >= 8 else { return false }
        let inputCJKRatio = Double(inputCounts.cjk) / Double(inputCounts.total)
        let outputCJKRatio = Double(outputCounts.cjk) / Double(outputCounts.total)
        return (inputCJKRatio >= 0.65 && outputCJKRatio <= 0.2)
            || (inputCJKRatio <= 0.2 && outputCJKRatio >= 0.65)
    }

    private static func scriptCounts(_ text: String) -> (cjk: Int, latin: Int, total: Int) {
        var cjk = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) { cjk += 1 }
            else if (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) { latin += 1 }
        }
        return (cjk, latin, cjk + latin)
    }

    private static func introducesSensitiveContent(input: String, output: String) -> Bool {
        !containsSensitivePattern(input) && containsSensitivePattern(output)
    }

    private static func containsSensitivePattern(_ text: String) -> Bool {
        let patterns = [
            #"(?i)\b(?:api[_-]?key|secret|access[_-]?token|password)\b\s*[:=]"#,
            #"(?i)\bBearer\s+[A-Za-z0-9._~+/-]{12,}={0,2}"#,
            #"-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----"#,
        ]
        return patterns.contains { pattern in
            text.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static func inventsProtectedFact(
        input: String,
        output: String,
        context: IntelliSenseContextSnapshot?,
        vocabulary: [String]
    ) -> Bool {
        let inputTokens = ProtectedFactExtractor.tokens(in: input) + mixedDigitTerms(in: input)
        // A user vocabulary spelling such as "Type4Me" is not an invented fact.
        // Terms without letters (versions, amounts) never get this exemption.
        let vocabularyTerms = vocabulary.filter { $0.rangeOfCharacter(from: .letters) != nil }
        let outputTokens = ProtectedFactExtractor.tokens(in: output) + mixedDigitTerms(in: output)
        let contextText = (context?.contextBeforeCursor ?? "") + "\n" + (context?.contextAfterCursor ?? "")
        let contextTokens = ProtectedFactExtractor.tokens(in: contextText) + mixedDigitTerms(in: contextText)
        let additions = outputTokens.filter { token in
            !inputTokens.contains(where: { $0.caseInsensitiveCompare(token) == .orderedSame })
                && !contextTokens.contains(where: { $0.caseInsensitiveCompare(token) == .orderedSame })
                && !vocabularyTerms.contains(where: { $0.caseInsensitiveCompare(token) == .orderedSame })
        }
        guard !additions.isEmpty else { return false }
        // "GPT 6" → "GPT-6" only re-spells a number the speaker said; a token is
        // invented when it carries a number the input never contained.
        let inputNumbers = spokenNumbers(in: input).union(inputTokens.flatMap(numbers(in:)))
        let inventedAdditions = additions.filter { !Set(numbers(in: $0)).isSubset(of: inputNumbers) }
        // New Arabic facts are hard errors when the source already contained
        // protected facts. For ASR-shaped Chinese-number normalization, emit no
        // hard rejection because the source may not contain an Arabic token.
        return !inputTokens.isEmpty && inventedAdditions.contains { token in
            token.rangeOfCharacter(from: .decimalDigits) != nil
                && !appearsOnlyAsListMarker(token, in: output)
        }
    }

    private static func numbers(in token: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)*"#) else { return [] }
        return regex.matches(in: token, range: NSRange(token.startIndex..., in: token)).compactMap {
            Range($0.range, in: token).map { String(token[$0]) }
        }
    }

    /// Every number the speaker said, in any spelling the polish may normalize to:
    /// digits glued to letters ("6GPT6", "Fib5.1"), one number split by ASR
    /// punctuation ("742。2", "26、901、512、31"), and Chinese numerals
    /// ("九点" → 9, "百分之四十" → 40, "十点半" → 10 and 30).
    private static func spokenNumbers(in text: String) -> Set<String> {
        var result = Set(numbers(in: text))
        if text.range(of: #"\d\s*点半"#, options: .regularExpression) != nil { result.insert("30") }
        if let run = try? NSRegularExpression(pattern: #"\d+(?:[ \t。．.、，,]{1,2}\d+)+"#) {
            for match in run.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                let parts = numbers(in: String(text[range]).replacingOccurrences(of: ".", with: " "))
                for start in parts.indices {
                    for end in parts.indices where end > start {
                        result.insert(parts[start...end].joined(separator: "."))
                    }
                }
            }
        }
        return result.union(chineseNumerals(in: text))
    }

    private static let chineseDigits: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]
    private static let chineseUnits: [Character: Int] = ["十": 10, "百": 100, "千": 1000, "万": 10000]

    private static func chineseNumerals(in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(
            pattern: #"([零〇一二两三四五六七八九十百千万]+)((?:点[零〇一二两三四五六七八九]+)*)(点半)?"#
        ) else { return [] }
        var result = Set<String>()
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let integerRange = Range(match.range(at: 1), in: text) else { continue }
            let integer = Array(text[integerRange])
            let fractions = Range(match.range(at: 2), in: text)
                .map { text[$0].split(separator: "点").map { $0.compactMap { chineseDigits[$0] }.map(String.init).joined() } }
                ?? []
            // Every suffix, so a stutter such as "二二百五十" still yields 250.
            for start in integer.indices {
                guard let value = chineseInteger(Array(integer[start...])) else { continue }
                result.insert(value)
                if !fractions.isEmpty {
                    result.formUnion(fractions)
                    for end in fractions.indices {
                        result.insert(([value] + fractions[...end]).joined(separator: "."))
                    }
                }
                if match.range(at: 3).location != NSNotFound {
                    result.formUnion(["30", value + ".5"])
                }
            }
        }
        return result
    }

    /// "二十六" → "26"; unit-less readings keep their digits: "二六" → "26", "零一" → "01".
    private static func chineseInteger(_ characters: [Character]) -> String? {
        guard !characters.isEmpty else { return nil }
        if !characters.contains(where: { chineseUnits[$0] != nil }) {
            let digits = characters.compactMap { chineseDigits[$0] }
            return digits.count == characters.count ? digits.map(String.init).joined() : nil
        }
        var total = 0, section = 0, digit: Int?
        for character in characters {
            if let value = chineseDigits[character] {
                digit = value
            } else if let unit = chineseUnits[character] {
                if unit == 10_000 {
                    total += (section + (digit ?? 0)) * unit
                    section = 0
                } else {
                    section += (digit ?? 1) * unit
                }
                digit = nil
            }
        }
        return String(total + section + (digit ?? 0))
    }

    /// Capitalization must not let a new brand/version bypass numeric-fact checks.
    /// References normalize only a verified local substitution before this check.
    private static func mixedDigitTerms(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])[A-Za-z][A-Za-z0-9_-]*[0-9][A-Za-z0-9_-]*(?![A-Za-z0-9_])"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func appearsOnlyAsListMarker(_ token: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        guard let marker = try? NSRegularExpression(
            pattern: #"(?m)^\s*"# + escaped + #"[.)、]\s*"#
        ) else { return false }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard marker.firstMatch(in: text, range: fullRange) != nil else { return false }
        let withoutMarkers = marker.stringByReplacingMatches(
            in: text,
            range: fullRange,
            withTemplate: ""
        )
        return !contains(token: token, in: withoutMarkers)
    }

    private static func adoptedContextTerm(
        input: String,
        output: String,
        context: IntelliSenseContextSnapshot
    ) -> Bool {
        let contextText = context.contextBeforeCursor + "\n" + context.contextAfterCursor
        let terms = ProtectedFactExtractor.tokens(in: contextText)
        return terms.contains { term in !contains(token: term, in: input) && contains(token: term, in: output) }
    }
}

// Compatibility spelling retained for existing product call sites while the
// richer validator result is adopted incrementally.
public typealias IntelliSenseOutputGuard = IntelliSenseOutputValidator
