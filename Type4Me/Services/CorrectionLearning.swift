import AppKit
import ApplicationServices
import Foundation
import Type4MeIntelliSenseCore

struct PostInjectionLearningOptions: Equatable, Sendable {
    var correctionEnabled: Bool
    var expressionLearningEnabled: Bool
    var appCategory: ApplicationCategory
}

struct PostInjectionLearningPlan: Equatable, Sendable {
    let correctionEnabled: Bool
    let expressionLearningEnabled: Bool

    var shouldTrackInjection: Bool {
        correctionEnabled || expressionLearningEnabled
    }

    static func resolve(
        settings: IntelliSenseSettings?,
        modeID: UUID,
        startedModeID: UUID?,
        isCrossModeFallback: Bool,
        aborted: Bool,
        guardRejected: Bool,
        contextAvailability: ContextAvailability?,
        targetBundleIdentifier: String?
    ) -> Self {
        let blocked = contextAvailability == .blacklisted
            || contextAvailability == .sensitive
            || settings?.isBlacklisted(bundleIdentifier: targetBundleIdentifier) == true
        let common = !aborted
            && !guardRejected
            && !blocked
            && modeID == ProcessingMode.intelliSenseId
        return Self(
            correctionEnabled: common && settings?.correctionDetectionEnabled == true,
            expressionLearningEnabled: common
                && settings?.expressionLearningEnabled == true
                && !isCrossModeFallback
                && startedModeID == ProcessingMode.intelliSenseId
        )
    }
}

/// Watches the text field after an injection and records the user's final edit
/// with the history record. Edits feed expression learning and, when enabled,
/// `VocabularyLearningStore`, which adds a term to the hotwords after the user
/// has corrected it twice. There is no confirmation card.
@MainActor
final class PostInjectionLearningCoordinator: NSObject {
    static let shared = PostInjectionLearningCoordinator()

    private struct ActiveObservation {
        let context: CorrectionObservationContext
        let observer: AXObserver
        let observesElementDestruction: Bool
        var options: PostInjectionLearningOptions
        let baselineVisibleValue: String
        let visibleInjectedRange: NSRange
        let visibleInjectedText: String
        var lastVisibleFullValue: String
        var lastReliableVisibleInjectedText: String
        var lastReliableObservedAt: Date
        var latestResolution: InjectedTextResolution
        var hasObservedVisibleChanges: Bool
    }

    private var active: ActiveObservation?
    private var timeoutTask: Task<Void, Never>?
    private var readRetryTask: Task<Void, Never>?
    private let historyStore: HistoryStore
    private let timing: UserEditObservationTiming
    private let vocabularyLearning: VocabularyLearningStore

    init(
        historyStore: HistoryStore = .shared,
        timing: UserEditObservationTiming = .production,
        vocabularyLearning: VocabularyLearningStore = .shared
    ) {
        self.historyStore = historyStore
        self.timing = timing
        self.vocabularyLearning = vocabularyLearning
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: .intelliSenseSettingsDidChange,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    static func supports(modeID: UUID) -> Bool {
        modeID == ProcessingMode.intelliSenseId
    }

    func begin(
        _ context: CorrectionObservationContext,
        options: PostInjectionLearningOptions
    ) {
        finalizeObservation(reason: .cancelled)
        guard Self.supports(modeID: context.modeID),
              options.correctionEnabled || options.expressionLearningEnabled
        else { return }

        let baselineProjection = VisibleTextProjection.project(context.baselineValue)
        guard let visibleInjectedRange = baselineProjection.projectedRange(
            from: context.injectedRange
        ) else {
            recordUnavailable(context: context)
            return
        }
        let visibleInjectedText = VisibleTextProjection.project(context.injectedText).text

        var observer: AXObserver?
        let createStatus = AXObserverCreate(context.processIdentifier, correctionAXObserverCallback, &observer)
        guard createStatus == .success, let observer else {
            DebugFileLogger.log("correction observer skipped: create status=\(createStatus.rawValue) bundle=\(context.bundleIdentifier)")
            recordUnavailable(context: context)
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let addStatus = AXObserverAddNotification(
            observer,
            context.element,
            kAXValueChangedNotification as CFString,
            refcon
        )
        guard addStatus == .success else {
            DebugFileLogger.log("correction observer skipped: add status=\(addStatus.rawValue) bundle=\(context.bundleIdentifier)")
            recordUnavailable(context: context)
            return
        }

        let destructionStatus = AXObserverAddNotification(
            observer,
            context.element,
            kAXUIElementDestroyedNotification as CFString,
            refcon
        )

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            CFRunLoopMode.commonModes
        )
        active = ActiveObservation(
            context: context,
            observer: observer,
            observesElementDestruction: destructionStatus == .success,
            options: options,
            baselineVisibleValue: baselineProjection.text,
            visibleInjectedRange: visibleInjectedRange,
            visibleInjectedText: visibleInjectedText,
            lastVisibleFullValue: baselineProjection.text,
            lastReliableVisibleInjectedText: visibleInjectedText,
            lastReliableObservedAt: Date(),
            latestResolution: InjectedTextResolution(
                text: visibleInjectedText,
                confidence: .exact,
                changedInsideInjection: false,
                changedOutsideInjection: false,
                failure: nil
            ),
            hasObservedVisibleChanges: false
        )
        DebugFileLogger.log("correction observer started: bundle=\(context.bundleIdentifier) injectedLength=\(context.injectedText.count)")

        timeoutTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.timing.observationTimeout)
            guard !Task.isCancelled else { return }
            self.finalizeObservation(reason: .timeout)
        }
    }

    /// Compatibility entry point for call sites and tests that only observe.
    func begin(_ context: CorrectionObservationContext) {
        begin(context, options: PostInjectionLearningOptions(
            correctionEnabled: true,
            expressionLearningEnabled: false,
            appCategory: AppContextClassifier.classify(
                bundleIdentifier: context.bundleIdentifier,
                appName: nil
            )
        ))
    }

    func cancelObservation() {
        finalizeObservation(reason: .cancelled)
    }

    func finalizeBeforeNextRecording() {
        finalizeObservation(reason: .nextRecording)
    }

    func finalizeBeforeRevise() {
        finalizeObservation(reason: .reviseStarted)
    }

    private func recordUnavailable(context: CorrectionObservationContext) {
        Task {
            _ = await historyStore.updateUserEditObservation(
                recordID: context.sourceRecordID,
                text: nil,
                status: .unavailable,
                observedAt: nil
            )
        }
    }

    private func finalizeObservation(reason: UserEditObservationEndReason) {
        guard var observation = active else { return }
        DebugFileLogger.log(
            "correction observer ending: record=\(observation.context.sourceRecordID) reason=\(reason.rawValue)"
        )
        // Clear active first. All callbacks run on MainActor, so this is the
        // single atomic finalization gate for every end path.
        active = nil
        timeoutTask?.cancel()
        readRetryTask?.cancel()
        timeoutTask = nil
        readRetryTask = nil

        var effectiveReason = reason
        if reason != .valueCleared, reason != .structureChanged,
           let currentSnapshot = copyObservedContentSnapshot(for: observation) {
            switch visibleTransition(currentSnapshot, observation: observation) {
            case .valueCleared:
                effectiveReason = .valueCleared
            case .structureChanged:
                effectiveReason = .structureChanged
            case .changed:
                applyResolution(visibleValue: currentSnapshot.visibleValue, to: &observation)
            case .unchanged:
                break
            }
        }

        AXObserverRemoveNotification(
            observation.observer,
            observation.context.element,
            kAXValueChangedNotification as CFString
        )
        if observation.observesElementDestruction {
            AXObserverRemoveNotification(
                observation.observer,
                observation.context.element,
                kAXUIElementDestroyedNotification as CFString
            )
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observation.observer),
            CFRunLoopMode.commonModes
        )

        settleHistoryAndLearning(observation: observation, reason: effectiveReason)
    }

    fileprivate func accessibilityValueDidChange(element: AXUIElement) {
        guard let active, CFEqual(active.context.element, element) else { return }
        captureCurrentValue(isRetry: false)
    }

    fileprivate func accessibilityElementWasDestroyed(element: AXUIElement) {
        guard let active, CFEqual(active.context.element, element) else { return }
        finalizeObservation(reason: .elementDestroyed)
    }

    @objc private func settingsDidChange() {
        Task { [weak self] in
            guard let self else { return }
            let settings = await IntelliSenseSettingsStore.shared.load()
            guard var active = self.active else { return }
            if settings.isBlacklisted(bundleIdentifier: active.context.bundleIdentifier) {
                self.finalizeObservation(reason: .appBlacklisted)
                return
            }
            active.options.correctionEnabled = active.options.correctionEnabled
                && settings.correctionDetectionEnabled
            active.options.expressionLearningEnabled = active.options.expressionLearningEnabled
                && settings.expressionLearningEnabled
            guard active.options.correctionEnabled || active.options.expressionLearningEnabled else {
                self.finalizeObservation(reason: .settingsDisabled)
                return
            }
            self.active = active
        }
    }

    @objc private func applicationDidTerminate(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication,
              application.processIdentifier == active?.context.processIdentifier
        else { return }
        finalizeObservation(reason: .appTerminated)
    }

    private func captureCurrentValue(isRetry: Bool) {
        guard var observation = active else { return }
        guard let currentSnapshot = copyObservedContentSnapshot(for: observation) else {
            if !isRetry {
                readRetryTask?.cancel()
                readRetryTask = Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: self.timing.readRetryDelay)
                    guard !Task.isCancelled else { return }
                    self.captureCurrentValue(isRetry: true)
                }
            } else {
                DebugFileLogger.log(
                    "user edit observation finalized: reason=readFailure "
                        + "bundle=\(observation.context.bundleIdentifier)"
                )
                finalizeObservation(reason: .readFailure)
            }
            return
        }
        readRetryTask?.cancel()
        readRetryTask = nil
        switch visibleTransition(currentSnapshot, observation: observation) {
        case .valueCleared:
            finalizeObservation(reason: .valueCleared)
        case .structureChanged:
            finalizeObservation(reason: .structureChanged)
        case .unchanged:
            break
        case .changed:
            applyResolution(visibleValue: currentSnapshot.visibleValue, to: &observation)
            active = observation
        }
    }

    private func applyResolution(
        visibleValue: String,
        to observation: inout ActiveObservation
    ) {
        observation.lastVisibleFullValue = visibleValue
        observation.hasObservedVisibleChanges = true
        let resolution = InjectedTextResolver.resolve(
            baseline: observation.baselineVisibleValue,
            injectedRange: observation.visibleInjectedRange,
            current: visibleValue,
            budget: timing.resolverBudget
        )
        observation.latestResolution = resolution
        guard resolution.confidence != .ambiguous,
              let resolvedText = resolution.text,
              !resolvedText.isEmpty
        else { return }
        observation.lastReliableVisibleInjectedText = resolvedText
        observation.lastReliableObservedAt = Date()
    }

    private func visibleTransition(
        _ snapshot: ObservedContentSnapshot,
        observation: ActiveObservation
    ) -> UserEditVisibleTransition {
        UserEditVisibleStateMachine.classify(
            currentVisibleValue: snapshot.visibleValue,
            isPlaceholder: snapshot.isPlaceholder,
            baselineVisibleValue: observation.baselineVisibleValue,
            visibleInjectedRange: observation.visibleInjectedRange,
            visibleInjectedText: observation.visibleInjectedText,
            lastReliableVisibleInjectedText: observation.lastReliableVisibleInjectedText,
            previousVisibleFullValue: observation.lastVisibleFullValue
        )
    }

    private func settleHistoryAndLearning(
        observation: ActiveObservation,
        reason: UserEditObservationEndReason
    ) {
        let settlement = UserEditObservationSettlement.resolve(
            original: observation.visibleInjectedText,
            lastReliableText: observation.lastReliableVisibleInjectedText,
            latestResolutionConfidence: observation.latestResolution.confidence,
            hasObservedExternalChanges: observation.hasObservedVisibleChanges,
            endReason: reason
        )
        let recordID = observation.context.sourceRecordID
        let observedAt = observation.lastReliableObservedAt

        Task {
            let updated = await historyStore.updateUserEditObservation(
                recordID: recordID,
                text: settlement.text,
                status: settlement.status,
                observedAt: observedAt
            )
            if !updated {
                DebugFileLogger.log(
                    "user edit observation history update failed: status=\(settlement.status.rawValue)"
                )
            }
        }

        if observation.options.correctionEnabled,
           settlement.status == .edited,
           let edited = settlement.text {
            let original = observation.visibleInjectedText
            let learning = vocabularyLearning
            Task { await learning.record(original: original, edited: edited) }
        }

        guard observation.options.expressionLearningEnabled,
              settlement.text != nil,
              settlement.classification == .expressionEdit
                || settlement.classification == .mixedEdit
        else { return }
        recordExpressionSample(
            active: observation,
            finalValue: observation.lastVisibleFullValue
        )
    }

    private func recordExpressionSample(active: ActiveObservation, finalValue: String) {
        guard let styleValue = observedInjectedText(
            baselineValue: active.baselineVisibleValue,
            injectedRange: active.visibleInjectedRange,
            injectedText: active.visibleInjectedText,
            currentValue: finalValue
        ) else { return }
        let observation = ExpressionObservation(
            sessionID: active.context.sourceRecordID,
            createdAt: Date(),
            appBundleIdentifier: active.context.bundleIdentifier,
            appCategory: active.options.appCategory,
            sourceText: active.context.sourceText,
            injectedText: active.visibleInjectedText,
            finalObservedText: styleValue,
            correctionCandidateRange: nil
        )
        let bundleIdentifier = active.context.bundleIdentifier
        Task {
            do {
                let settings = await IntelliSenseSettingsStore.shared.load()
                guard settings.expressionLearningEnabled,
                      !settings.isBlacklisted(bundleIdentifier: bundleIdentifier)
                else { return }
                try await ExpressionProfileStore.shared.record(observation)
            } catch {
                DebugFileLogger.log(
                    "expression profile save failed bundle=\(bundleIdentifier) "
                        + "error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func observedInjectedText(
        baselineValue: String,
        injectedRange: NSRange,
        injectedText: String,
        currentValue: String
    ) -> String? {
        let baseline = baselineValue as NSString
        guard injectedRange.location >= 0,
              NSMaxRange(injectedRange) <= baseline.length
        else { return nil }
        let prefix = baseline.substring(to: injectedRange.location)
        let suffix = baseline.substring(from: NSMaxRange(injectedRange))
        guard currentValue.hasPrefix(prefix), currentValue.hasSuffix(suffix),
              currentValue.count >= prefix.count + suffix.count else {
            return currentValue == baselineValue ? injectedText : nil
        }
        let start = currentValue.index(currentValue.startIndex, offsetBy: prefix.count)
        let end = currentValue.index(currentValue.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return nil }
        return String(currentValue[start..<end])
    }

    private func copyStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private struct ObservedContentSnapshot {
        let rawValue: String
        let visibleValue: String
        let isPlaceholder: Bool
    }

    private func copyObservedContentSnapshot(
        for observation: ActiveObservation
    ) -> ObservedContentSnapshot? {
        let element = observation.context.element
        guard let rawValue = copyStringAttribute(kAXValueAttribute as CFString, from: element) else {
            return nil
        }
        let contentValue = UserEditObservedValueSanitizer.contentValue(
            rawValue,
            placeholderCandidates: observation.context.placeholderCandidates.map(Optional.some) + [
                copyStringAttribute(kAXPlaceholderValueAttribute as CFString, from: element),
                copyStringAttribute(kAXDescriptionAttribute as CFString, from: element),
            ]
        )
        let isPlaceholder = contentValue.isEmpty && !rawValue.isEmpty
        return ObservedContentSnapshot(
            rawValue: rawValue,
            visibleValue: isPlaceholder
                ? ""
                : VisibleTextProjection.project(contentValue).text,
            isPlaceholder: isPlaceholder
        )
    }
}

typealias CorrectionLearningCoordinator = PostInjectionLearningCoordinator

private let correctionAXObserverCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let coordinator = Unmanaged<PostInjectionLearningCoordinator>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    Task { @MainActor in
        switch notification as String {
        case kAXValueChangedNotification:
            coordinator.accessibilityValueDidChange(element: element)
        case kAXUIElementDestroyedNotification:
            coordinator.accessibilityElementWasDestroyed(element: element)
        default:
            break
        }
    }
}
