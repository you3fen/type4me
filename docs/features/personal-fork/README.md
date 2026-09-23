# Personal dictation integration

This is a **fork-only preview**, not an upstream release. Upstream remains
`joewongjc/type4me`; no upstream branch or PR is modified by this integration.

## Provenance

- Upstream `main`: `9d638db9082a6f8358d3aa2e7c44430654f0ad7c`.
- PR #310: `d8c69dd88249a26d6f6755375572e3459f207a26` (including its pricing update).
- PR #309: `abba81746785bfb99b0ad524914e924a370f525d`; its destination-scene
  timing is preserved, with the existing #310-compatible overlay.
- Reviewed vocabulary patch: mixed-script/whitespace boundary correction,
  bounded personal vocabulary in the existing Intelli Sense request, and
  non-content diagnostic events.

## Personal changes: accuracy pipeline (2026-09-23)

One vocabulary list (`hotwords.json`) is used in three places:

1. **Volcano ASR**: sent as `request.corpus.context` (`{"hotwords":[{"word":…}]}`),
   deduplicated and capped at the documented 100-token direct-pass budget. The
   cloud boosting-table sync and `context_history_length` were removed.
2. **Accent-tolerant pinyin pass** (`PhoneticVocabularyMatcher`): after snippets,
   in every mode. Folds an/ang, en/eng, in/ing, z/zh, c/ch, s/sh and n/l, and
   rewrites only terms of three or more Chinese characters on word-aligned
   windows that are not themselves dictionary words (身材有数 → 生财有术). Two-
   character homophones are never touched; an LLM hint for them rewrote real
   words (会花 → 会话) and was removed. Rewrites are recorded in history with
   `origin: phoneticVocabulary`.
3. **Intelli Sense prompt**: the existing 20-term / 400-character personal
   vocabulary block. The output guard accepts a new token only when it is a
   vocabulary term with letters (e.g. `Type4Me`); versions and amounts are
   still protected.

Exact replacement rules (`snippets.json`, per-app `app-snippets/`) are unchanged.

**Learning from edits** (`VocabularyEditLearner`, `VocabularyLearningStore`): the
post-injection AX observer still records the final edit with the history record.
When "从修改中学习热词 / Learn Hotwords from Edits" is on, a single contiguous term
replacement (Chinese 2–8 characters of equal length, or a Latin-led 3–30
character term; not case-only, not numbers) is counted in
`vocabulary-learning.json`. The second correction to the same term appends it to
the hotwords. There is no confirmation card. A replay over local history
promoted only real terms (Type4Me, Codex, 菜獾, 生财有术, Raycast, Claude).

Removed with this change (Plan A and the upstream immediate-correction stack):
confirmed spelling references and their sheet, the floating correction card,
immediate/affinity/batch correction analyzers, CppJieba, the smart-correction
sheet and built-in hotword/snippet lists. Historical design and verification
notes in this folder describe those removed features.

## Isolation and build

`TYPE4ME_PERSONAL_BUILD=1` without `TYPE4ME_DEV_BUILD=1` keeps the isolated
preview namespace. `scripts/package-personal.sh` supplies this app identity:
- App/Bundle: `Type4Me Personal` / `com.you3fen.type4me.personal`;
- data: `~/Library/Application Support/Type4Me Personal/`;
- Keychain services prefixed `com.you3fen.type4me.personal`;
- URL scheme `type4me-personal`.

No automatic import of production/dev history, dictionary or credentials.
Configure your own keys in the preview app. No production/default namespace is
changed by the flag-free build. Personal builds disable the upstream in-app
updater and do not seed the broad example forced snippet on first use.

Build from a clean cloud-only checkout with `bash scripts/package-personal.sh`.
This packages in `dist/`, **does not install or launch** the app, and embeds the
source commit and data namespace. CI uses ad-hoc signing, not notarization or
any developer's private signing certificate. Microphone/accessibility consent
and real target-app behavior require user-side acceptance. App bundles from
CI should be treated as test previews, not a validated replacement.

### Personal build replacing an existing Dev app

Set both `TYPE4ME_PERSONAL_BUILD=1` and `TYPE4ME_DEV_BUILD=1`. Personal identity
and upstream-update blocking stay enabled, while data uses
`~/Library/Application Support/Type4Me/` and Keychain services remain
`com.type4me.grouped` / `com.type4me.scalar`. UserDefaults stays in the installed
Dev bundle's domain; do not copy production preferences into it. Vocabulary
learning state and data backups follow the shared directory.

Use the existing Dev packager in a clean cloud-only worktree, staging first:

```bash
TYPE4ME_PERSONAL_BUILD=1 TYPE4ME_DEV_BUILD=1 \
APP_NAME="Type4Me Dev" APP_BUNDLE_ID=com.type4me.dev URL_SCHEME=type4me-dev \
APP_PATH="/path/to/staging/Type4Me Dev.app" APP_BUILD=3093 \
CODESIGN_IDENTITY="Type4Me Dev" ARCH=universal VARIANT=cloud \
bash scripts/package-app.sh
```

The identity values above are examples: inspect the installed Dev app and reuse
its name, bundle ID, scheme, certificate and designated requirement. Do not use
`package-personal.sh` for this shared-data build. Verify the staged signature
and requirement before quitting both apps, backing up the old Dev app, shared
data, consistent SQLite snapshots and both
preference domains. Replace only the Dev app. Preserve Keychain access control;
restore the old app if launch fails. Do not run stable and Dev simultaneously
while checking the shared data.

Run the namespace tests with both flags, personal only, Dev only and neither;
run `DataBackupManagerTests` and `PersonalVocabularyIntegrationTests` for the
shared personal Dev build. Tests use synthetic data and temporary stores.

## Tests and limits

`VocabularyEditLearnerTests`, `PhoneticVocabularyMatcherTests` and
`VolcProtocolTests` cover the learning rules, pinyin folding/word boundaries and
the Volcano request shape with examples shaped after real history.
`PersonalVocabularyIntegrationTests` and `PersonalProvenanceIntegrationTests` use
deterministic mocks for the single-request prompt and guard wiring. These are
not ASR or model accuracy measurements; real dictation remains the acceptance.

Known limits: learning runs only in Intelli Sense mode; the pinyin pass uses
Apple's default reading for polyphonic characters; two-character accent errors
rely on hotword boosting and the LLM.
