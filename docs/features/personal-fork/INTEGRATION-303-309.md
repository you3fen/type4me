# Personal fork: #303 and reviewed #309 integration

## Fixed inputs

- Previous personal version: `962b7308532a455182ec95fbd1a793d3ee977a3a`.
- Upstream baseline including #303 and local backup support:
  `14bd28bd9ef4d65511e53a745ff33fe3086a0c32`.
- Reviewed #309: `225a2c891f2d744be225fd3826976d3316688fb2`.
- #310 already present, unchanged: `d8c69dd88249a26d6f6755375572e3459f207a26`.

The resulting personal branch retains both development histories. No rewrite
of `main` or the upstream-contribution branch is needed. The original
`README.md` provenance list documents the initial preview; these are the
inputs of this subsequent integration.

## Integration decisions

1. One snippet executor produces text, applied-rule provenance and non-content
   diagnostic callbacks. App overrides and chained rules have a single order.
   A separately loaded rule list is not labelled as the executed snapshot.
2. When the destination changes during bounded context capture, recompute
   from the original transcript and replace both text and provenance, including
   an explicitly empty rule list. Personal references use that same processing
   snapshot. A later receiver switch does not trigger another LLM request.
3. Pre-injection learning gates preserve the processing destination's sensitive
   or blacklisted status. Existing native paste and unknown-context policies
   remain unchanged; unknown is not claimed to mean safe.
4. Keep the personal word list, explicit app-scoped spelling references,
   evidence-aware output guard, and #310 usage accounting. The default learning
   action is still not an unconditional global replacement.
5. Backup source and destination follow `AppDataNamespace`: personal builds
   read `Type4Me Personal/` and write `Type4Me Personal Backups/`. Include
   `correction-references.json`. Flag-free builds retain the original profile
   and backup names. No automatic production-to-personal import is added.
6. History contains the rule result before LLM processing and the rules that
   actually ran. Old rows remain unknown rather than inferred from today's
   dictionary. These local history fields can contain user vocabulary; they
   are not copied to CI or placed in diagnostic log messages.

## Verification boundary

`PersonalProvenanceIntegrationTests` combines destination changes, rule
provenance, personal references, one-call processing, numeral protection,
sensitive gating, temporary history persistence and backup namespace controls.
The history composition test deliberately stops before actual AX/clipboard
injection and explicitly writes the returned result to its own temporary DB.
It does not claim to test the production injection/history-write tail.

Run the full offline suite on macOS with `TYPE4ME_PERSONAL_BUILD=1` and an
isolated `CFFIXED_USER_HOME`; also check backup/provenance tests in a separate
flag-free build. CI logs, not this document, establish which checks passed.
No live ASR/LLM request, recording, on-device acceptance or accuracy improvement
is implied by these synthetic tests. Existing compound-edit, old forced-rule
and unrelated general-polishing limitations remain.

## Handoff for Codex on the user's Mac

Use the final commit of `you3fen/type4me:feat/personal-dictation` provided with
this handoff. Fetch it into an independent worktree after checking existing
work, rather than resetting an active checkout. Do not reapply #303, #309,
#310 or previous patch ZIPs: they are already integrated.

Follow `scripts/package-personal.sh` for a pure personal build; do not use the
production deploy script. Package first without installing or launching:

```sh
ARCH=universal CODESIGN_IDENTITY=- bash scripts/package-personal.sh
```

Verify the embedded commit, `Type4Me Personal` identity, personal Bundle ID,
URL scheme and data/backup namespaces. Do not overwrite the current App,
import private data or activate paid model requests as part of building.
Preserve the existing version for rollback. Real microphone, accessibility,
text delivery and recognition-quality acceptance belong to the user.
