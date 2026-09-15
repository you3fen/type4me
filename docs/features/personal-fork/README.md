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

## Personal changes

A correction confirmation defaults to an **app-scoped spelling reference**.
It saves the wrong/right pair even when the canonical hotword already exists.
Repeating an identical confirmation returns "already recorded". It does not
create or modify a forced snippet. "Always replace globally" is a separate,
unchecked opt-in; old manually configured snippets retain their semantics.
The References sheet in Vocabulary can inspect/remove learned pairs. This
removes reference evidence, not a separately configured hotword or snippet.

On the next Intelli Sense request, eligible references from the same app are
selected using the frozen processing scene (not the eventual paste recipient).
Only unambiguous, uniquely present source spans are considered; quoted/code/
path/identifier and explicit preservation contexts abstain. Budget: 12 pairs,
800 term characters; store cap: 256 pairs. The original hotword prompt budget
remains 20 terms/400 term characters. Character limits are not token limits.

The single existing LLM request receives the references as escaped data, not
instructions or unconditional replacements. No extra LLM call, ASR model,
recording, screen scraping or global fuzzy substitution is introduced. Quick
mode never calls this reference/polishing path. Model behavior remains to be
validated with real dictation; deterministic/mock tests are not accuracy tests.

The output validator recognizes only exact, local, evidenced replacements with
matching surrounding anchors. It normalizes a *validation copy* of the input;
never rewrites the model output or whitelists the whole personal dictionary.
Other checks (numbers, versions, negations, paths, etc.) remain enabled. On
rejection it returns the original input. Aggressive simultaneous rephrasing may
abstain; this is intentional. Digit-bearing brand handling is case-independent.

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
Dev bundle's domain; do not copy production preferences into it. Correction
references and data backups follow the shared directory.

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
data (including correction references), consistent SQLite snapshots and both
preference domains. Replace only the Dev app. Preserve Keychain access control;
restore the old app if launch fails. Do not run stable and Dev simultaneously
while checking the shared data.

Run the namespace tests with both flags, personal only, Dev only and neither;
run `DataBackupManagerTests` and `PersonalVocabularyIntegrationTests` for the
shared personal Dev build. Tests use synthetic data and temporary stores.

## Tests and limits

`CorrectionReferenceTests` covers persistence/duplicates/failures, same-app
selection, old JSON decoding, numeral-preserving edits, negative contexts and
namespace isolation. `PersonalVocabularyIntegrationTests` uses a deterministic
mock to check one-call processing and validator wiring. Existing destination,
learning, guard and usage tests remain. No personal history or vocabulary files
are committed; examples are synthetic and no paid model calls are made by CI.

Known limits: some compound/multiple manual edits still fail the original
candidate gates; old global snippets can still over-replace; the general guard
is not a semantic proof and an unrelated trailing-explanation gap remains.
Reference selection is conservative and depends on app identity and reliable
observed editing. A confirmed spelling alone is not an acoustic ground truth.
