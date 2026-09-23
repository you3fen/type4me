import AppKit
import ApplicationServices
import Foundation
import Type4MeIntelliSenseCore

struct TrackedInjectionContext: @unchecked Sendable {
    let element: AXUIElement
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let baselineValue: String
    let injectedRange: NSRange
    let beforeSelectedRange: NSRange?
    let afterSelectedRange: NSRange?
    let placeholderCandidates: [String]
    let sourceText: String
    let injectedText: String
    let sourceRecordID: String
    let modeID: UUID
    let createdAt: Date

    init(
        element: AXUIElement,
        processIdentifier: pid_t,
        bundleIdentifier: String,
        baselineValue: String,
        injectedRange: NSRange,
        beforeSelectedRange: NSRange?,
        afterSelectedRange: NSRange?,
        placeholderCandidates: [String],
        sourceText: String,
        injectedText: String,
        sourceRecordID: String,
        modeID: UUID,
        createdAt: Date = Date()
    ) {
        self.element = element
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.baselineValue = baselineValue
        self.injectedRange = injectedRange
        self.beforeSelectedRange = beforeSelectedRange
        self.afterSelectedRange = afterSelectedRange
        self.placeholderCandidates = placeholderCandidates
        self.sourceText = sourceText
        self.injectedText = injectedText
        self.sourceRecordID = sourceRecordID
        self.modeID = modeID
        self.createdAt = createdAt
    }
}

typealias CorrectionObservationContext = TrackedInjectionContext

struct TrackedInjectionResult: @unchecked Sendable {
    let outcome: InjectionOutcome
    let context: TrackedInjectionContext?

    var observationContext: TrackedInjectionContext? { context }

    init(outcome: InjectionOutcome, context: TrackedInjectionContext?) {
        self.outcome = outcome
        self.context = context
    }

    init(outcome: InjectionOutcome, observationContext: TrackedInjectionContext?) {
        self.outcome = outcome
        self.context = observationContext
    }
}
