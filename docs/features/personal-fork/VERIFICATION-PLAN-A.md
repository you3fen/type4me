# Plan A: native verification and delivery

## Fixed source and native evidence

- Repository/branch: `you3fen/type4me:feat/personal-dictation` only.
- Product baseline: `5273afdee55260c65816a60b3086cc287f795f4d`.
- Workflow input: `a951615db5a29da2650e240bd1e5782e34aaebac`.
- Tested and promoted product commit: `91285db537d7e018589782087a8534b8914d062f`.
- Tested tree: `5d0467f2ea0f60d54dd8e8fa1faaeeddc677fd6b`.
- GitHub Actions run: `35037054620`; job: `104608408885`; conclusion: success.
- Artifact ID: `10423528627`, name:
  `plan-a-evidence-a951615db5a29da2650e240bd1e5782e34aaebac`.
- Artifact ZIP SHA-256:
  `291f5c5befb04f83749d019626ecb978955cd729e31ff9948d90a13bfb42821b`.
- Product patch against the baseline SHA-256:
  `5ae0b00c9ed5da2e3aced716e0a0ef01b5796fd4a0cdfdc7d47c3b7135eb0e8b`.

The downloaded artifact digest was checked against GitHub metadata. All 20
changed/new product, test and design/handoff files in source.zip matched the
local reviewed final manifest, byte-for-byte by SHA-256. The workflow input
is a staging commit, NOT the tested product: provenance.txt and candidate-sha.txt
identify the actual commit. No production code was promoted after a failed run.

## Results checked in the retained raw logs

- Toolchain: macOS 26.6.2 (25G83), Xcode 26.6 (17F113), Swift 6.3.3.
- Personal + Dev flags: full suite reported 1,247 XCTest cases, 2 opt-in live
  account cases skipped, 0 failures; all 5 Swift Testing cases passed.
- New Plan A suites: 23 deterministic tests plus 3 real-session/mock tests,
  all passed. These are INCLUDED in the full-suite count, not additional.
- Both flags off, separate home and build directory: 73 selected compatibility,
  reference, backup, snippet and Plan A tests, 0 failures.
- The unchanged hotkey timing case was run independently six times and then
  again as part of the full suite; all these runs passed.
- Universal public/cloud Dev bundle: arm64 and x86_64, version 2.8.0 (CI build 1),
  successful release packaging and strict ad-hoc signature verification.
  Embedded source: 91285db537d7e018589782087a8534b8914d062f;
  data namespace: Type4Me; Bundle ID: com.type4me.dev.
- Portable Linux validation: 78 constructed-data XCTest cases passed. This
  exercises real core/writer code and an explicit-list snippet adapter, not
  macOS UI or end-to-end speech accuracy.
- Applying/reversing the product patch restored all 512 tracked files in the
  isolated text-source snapshot. This is source rollback, not a user-data restore test.

Earlier native attempts exposed two source-compatibility issues (Swift type
inference time and a defaulted-argument function reference); both were fixed.
Run 35036735569 compiled and passed the new suites but had three failed
assertions in ONE unchanged timing test:
HotkeyStateMachineTests.testScenario5_CleanHoldPastDelayStartsAndStopsNormallyOnReduction.
Its assertions and production implementation were NOT weakened or skipped.
The repeated checks and fresh-home full suite above passed. The earlier
failure remains recorded; no claim is made that scheduler flakiness is cured.

## Publication and scope

The workflow published the tested product only after both test configurations,
packaging, provenance export and artifact upload succeeded, using a non-force
push to the same personal branch and rejecting unexpected branch movement.
The following cleanup commit only removes temporary .github/plan-a-staging
payloads and plan-a-staging.yml and adds this verification document. It does
not change the tested product or tests. Use the final personal branch head;
do not reapply the archived patch to an already updated branch.

Upstream main and own-fork main were re-read at 14bd28bd9ef4d65511e53a745ff33fe3086a0c32;
reviewed PR #309's source remains 225a2c891f2d744be225fd3826976d3316688fb2.
No upstream branch, main branch or PR-source branch was written. No PR was
opened. The existing #303, #309 and #310 integration was not replayed.

## Acceptance boundary

All new examples are constructed; session results use controlled mock replies.
Tests ran in disposable homes and temporary stores, without the user's real
dictionary/history/credentials, live ASR/LLM requests or local installation.
The universal CI App is compile evidence, NOT a drop-in replacement for the
user's signed Dev identity. Do not install compile-only-DO-NOT-INSTALL.zip over it.

Codex on the user's Mac must follow CODEX-DEV-ACCEPTANCE.md: inspect and preserve
the actual installed Dev identity/signature/preferences, stage a build with
both TYPE4ME_PERSONAL_BUILD=1 and TYPE4ME_DEV_BUILD=1, verify shared data and
Keychain requirements, back up locally, and replace only Dev. Real microphone,
AX delivery, UI usability, recognition accuracy and perceived latency still
require the user's acceptance. Existing forced snippets are not silently
migrated; provider hotword limits/precedence and conservative reference gates
remain as documented in PLAN-A.md.
