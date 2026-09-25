import XCTest
@testable import Type4Me

final class TextInjectionOutcomeTests: XCTestCase {

    func testShouldRestoreClipboardMatchesPolicy() {
        XCTAssertTrue(TextInjectionEngine.shouldRestoreClipboard(retention: .restoreOriginal))
        XCTAssertFalse(TextInjectionEngine.shouldRestoreClipboard(retention: .retainResult))
    }

    func testResolveDeliveryTargetFallbackConditions() {
        // 1. Nil frontmost app
        XCTAssertEqual(
            TextInjectionEngine.resolveDeliveryTarget(frontmost: nil, selfBundleIdentifier: "com.type4me.app"),
            .fallbackToClipboard
        )

        // 2. Type4Me itself is frontmost (matches selfBundleIdentifier)
        let currentApp = StubRunningApplication(bundleIdentifier: "com.type4me.app", isTerminated: false)
        XCTAssertEqual(
            TextInjectionEngine.resolveDeliveryTarget(
                frontmost: currentApp,
                selfBundleIdentifier: currentApp.bundleIdentifier
            ),
            .fallbackToClipboard
        )

        // 3. Different app that is alive resolves to .app
        XCTAssertEqual(
            TextInjectionEngine.resolveDeliveryTarget(
                frontmost: currentApp,
                selfBundleIdentifier: "com.other.unique.bundle.id"
            ),
            .app(currentApp)
        )

        // 4. A terminated app cannot receive the result.
        let terminatedApp = StubRunningApplication(bundleIdentifier: "com.editor.app", isTerminated: true)
        XCTAssertEqual(
            TextInjectionEngine.resolveDeliveryTarget(
                frontmost: terminatedApp,
                selfBundleIdentifier: "com.type4me.app"
            ),
            .fallbackToClipboard
        )
    }

    private typealias Snapshot = TextInjectionEngine.FocusedElementSnapshot

    private func field(_ value: String?, element: AXUIElement = AXUIElementCreateApplication(1)) -> Snapshot {
        Snapshot(element: element, value: value, isEditable: true, hasFocusedElement: true)
    }

    func testRichEditorParagraphsCountAsDelivered() {
        // A rich editor stores "\n\n" as a paragraph break, so the exact range
        // cannot be located even though the whole dictation is there.
        let pasted = "第一段内容。\n\n第二段内容。"
        let result = TextInjectionEngine.assessUnlocatedPaste(
            before: field(""),
            after: field("第一段内容。\n第二段内容。"),
            pastedText: pasted
        )
        XCTAssertTrue(result.landed)
    }

    func testUnreadableFieldIsUnproven() {
        // Focus alone does not prove Cmd+V landed; keep the dictation on the
        // clipboard rather than risk leaving it only in history.
        let result = TextInjectionEngine.assessUnlocatedPaste(
            before: nil,
            after: field(nil),
            pastedText: "我头已经戒了。"
        )
        XCTAssertFalse(result.landed)
        XCTAssertEqual(result.reason, "valueUnreadable")
    }

    func testFieldWithoutPrePasteSnapshotCountsWhenItHoldsTheText() {
        // WeChat-style: the pre-paste focus query fails, but the field read
        // after Cmd+V contains the dictation.
        let result = TextInjectionEngine.assessUnlocatedPaste(
            before: nil,
            after: field("我头已经戒了。"),
            pastedText: "我头已经戒了。"
        )
        XCTAssertTrue(result.landed)
    }

    func testFocusOutsideAnEditableFieldIsUnproven() {
        let result = TextInjectionEngine.assessUnlocatedPaste(
            before: Snapshot(hasFocusedElement: true),
            after: Snapshot(hasFocusedElement: true),
            pastedText: "一段很长的听写"
        )
        XCTAssertFalse(result.landed)
        XCTAssertEqual(result.reason, "noEditableFocus")
    }

    func testFocusMovingToAnotherFieldIsUnproven() {
        let result = TextInjectionEngine.assessUnlocatedPaste(
            before: field("", element: AXUIElementCreateApplication(1)),
            after: field("一段很长的听写", element: AXUIElementCreateApplication(2)),
            pastedText: "一段很长的听写"
        )
        XCTAssertFalse(result.landed)
        XCTAssertEqual(result.reason, "focusMoved")
    }

    func testReadableFieldWithoutThePastedTextIsUnproven() {
        let result = TextInjectionEngine.assessUnlocatedPaste(
            before: field("旧内容"),
            after: field("旧内容"),
            pastedText: "新的听写"
        )
        XCTAssertFalse(result.landed)
        XCTAssertEqual(result.reason, "textNotFound")
    }

    func testTextAlreadyInTheFieldBeforePasteIsNotProofOfDelivery() {
        let result = TextInjectionEngine.assessUnlocatedPaste(
            before: field("可以。"),
            after: field("可以。"),
            pastedText: "可以。"
        )
        XCTAssertFalse(result.landed)
    }
}

private final class StubRunningApplication: NSRunningApplication {
    private let testBundleIdentifier: String
    private let testIsTerminated: Bool

    init(bundleIdentifier: String, isTerminated: Bool) {
        testBundleIdentifier = bundleIdentifier
        testIsTerminated = isTerminated
        super.init()
    }

    override var bundleIdentifier: String? { testBundleIdentifier }
    override var isTerminated: Bool { testIsTerminated }
}
