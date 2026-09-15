# Plan A: converge vocabulary confirmation, not another correction layer

Base: `5273afdee55260c65816a60b3086cc287f795f4d` on
`you3fen/type4me:feat/personal-dictation`. Fork-only; do not reapply #303,
reviewed #309 or #310. Do not change upstream or their PR-source branches.

## User-visible contract

- Canonical names feed existing ASR hotword handling. The ASR transports and
  their limits/cloud-table precedence are unchanged; local save is not a claim
  that a provider already synchronized or recognized a word.
- The observer confirmation, history correction and advanced correction sheet
  use the same writer and choice vocabulary. Observer confirmations still
  default to an App-scoped reference. History/advanced entry points without a
  trustworthy origin App default to hotword-only. Explicit sharing or global
  forced expansion is a separate choice, never inferred from a correction.
- History confirmation updates an existing equivalent forced trigger when that
  explicit mode is chosen; it no longer silently claims success without a save.
- Advanced generated variants are predictions, initially unchecked. They never
  become confirmed references. Only explicitly selected forced expansion mode
  can save predicted snippets. Saving the original confirmed pair needs no LLM.
- Canonical renaming from Hotwords or the grouped References view updates the
  hotword and reference targets together. Deleting a name asks before deleting
  its associated references. Neither operation changes explicit shortcuts.
  Bulk hotword editing remains a hotword-only operation: no inferred renames or
  deletion of reference evidence.
- Reference sharing is explicit. Existing JSON without `sharedAcrossApps`
  remains App-local. The optional field is ignored by old builds, whose
  behavior stays restricted to the origin App. Manual confirmations use the
  non-App origin marker `type4me:manual-confirmation`; an old build will not
  apply those shared references to a real App. No database migration is needed.
- Actual App-specific references override shared references of the same
  normalized trigger; ambiguity within that scope abstains. Trigger identity
  strips whitespace and case consistently for snippet override, explicit
  replacement updates and reference conflict checks. Display spellings and
  punctuation are not rewritten by identity normalization.
- The existing 20-term/400-character LLM budget remains. Current confirmed
  evidence and exact case/space-insensitive lexical relevance are prioritized
  before stable legacy order. This is not phonetic inference, a guarantee that
  every new name fits, or a new retrieval/model service. Provider hotword caps
  and the conservative reference selection limits are unchanged.
- The existing validator also checks literal quotes/backticks/underscore
  identifiers and a narrowly defined simple negation deletion. General
  paraphrase, preserved numbers and original fail-safe fallback remain. This
  is not a semantic proof. Explicit quick expansions still intentionally run
  first and retain their legacy behavior, including matching in paths/quotes;
  old forced rules are not automatically converted or removed.
- Save errors are surfaced. Hotword sync starts only after all confirmation
  writes succeed. Multi-file rollback is best effort, not an ACID transaction;
  an incomplete rollback has its own error. Do not run stable/Dev concurrently
  against the shared profile while testing.

## Evidence and limits

Portable Swift 6.2.1 validation ran 78 XCTest cases with zero failures,
including 23 new constructed-data tests plus existing prompt/guard/snippet
regressions. The core and writer are real source; the Linux snippet test
adapter extracts the real explicit-list executor and excludes caches/OS I/O.
It does not test AppKit, AX, the clipboard, provider requests or real models.

`VocabularyPlanASessionTests` adds three macOS session/mock checks for bounded
new-word selection, explicit cross-App reference reuse and privacy gating,
including the existing one-call path. Native macOS CI logs, not this document,
establish full-App compilation/test/package results. See the workflow run
associated with the promotion commit and its source/hash manifest.

All new examples are constructed. No user history, dictionary, credentials or
recorded audio was accessed. Real ASR/LLM accuracy and installed-Dev identity
acceptance remain the user's local build/manual-testing stage. See
`CODEX-DEV-ACCEPTANCE.md`. Never install an ad-hoc CI preview over an existing
signed Dev app without preserving its identity and Keychain requirements.
