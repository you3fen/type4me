# Verification of the personal #303 / reviewed #309 integration

## Evidence

- GitHub Actions run: `you3fen/type4me/actions/runs/35022070889`.
- Job: `104559955801`, `validate-integration`, completed successfully.
- Validated staging commit: `32ff4a9a6d1676180e0e671a8b618e0f1ab282de`.
- Validated staging tree: `899080fd20defbf387a60489d30d0a6e7d68d16b`.
- Artifact: `10417154671`,
  `personal-integration-evidence-97b2ec4cb12e67d48d7291b7d3c855e5cc30db35`.
- Artifact ZIP SHA-256:
  `85af848fa10153b5f3eeb1aa3b8d35d5384344940837c0de0ab0b3dd186a9dee`.

The artifact name identifies the workflow input commit. The workflow creates
and tests a local merge; `provenance.txt` identifies the actual tested commit
above. Both test steps succeeded before the workflow pushed that merge to the
integration branch. The artifact bytes were downloaded and their digest and
summaries checked before promotion.

## Results from the retained logs

Personal build (`TYPE4ME_PERSONAL_BUILD=1`), full `swift test`:
- 1,219 XCTest cases reported; 2 opt-in live Codex cases skipped; 0 failures.
- The additional Swift Testing suite passed all 5 cases.
- All 9 `PersonalProvenanceIntegrationTests` passed.

Flag-free build (`TYPE4ME_PERSONAL_BUILD=0`), separate build directory/home:
- 49 selected backup, provenance, snippet and combined integration tests;
  0 failures, no skips reported.

Toolchain recorded by this run: macOS 26.6.2, Xcode 26.6, Swift 6.3.3.
The disposable test homes contain no user's real data. No live ASR/LLM request,
recording, application installation or on-device acceptance was performed.

An earlier attempt exposed a test-only expectation error: the test target did
not inherit the executable target's personal compilation condition. The test
now inspects `AppDataNamespace.isPersonal` and retains exact assertions for
both namespace variants. No production gate or existing assertion was weakened
in response to that failure. The results above are from the subsequent run.

## Promotion

The published personal merge uses these parents directly:
1. Previous personal branch: `962b7308532a455182ec95fbd1a793d3ee977a3a`.
2. Reviewed upstream-contribution branch: `225a2c891f2d744be225fd3826976d3316688fb2`.

Its product source, test files and packaging configuration are identical to
the validated staging tree. The only tree differences at promotion are removal
of the temporary integration workflow and resolver script, and addition of
this verification note. This keeps one-time integration scaffolding out of
the personal branch's production history. The staging branch remains an audit
reference; it is not the branch to build for daily use.

`main` and the PR #309 source branch are not update targets of this promotion.
Build the exact published personal commit using the handoff in
`INTEGRATION-303-309.md`, without reapplying old PRs or patch archives. These
synthetic results establish integration behavior, not improved speech accuracy.
