# Immediate correction discovery repair (2026-09-16)

## Request, not a prescribed architecture

The user needs ordinary selected replacement and backspace/delete followed by
retyping to produce useful correction confirmations. They accept abstaining on
an ambiguous single character, and are willing to replace an entire term. They
also asked about front/back nasal and n/l pronunciation confusion. This change
is not a new ASR model, automatic global replacement policy, or bulk learner.

## Version boundaries

- Remote personal integration base: `727a36355d7ce7e630824835d7ad32cdcbb5492a`.
- Its product/test files match `91285db537d7e018589782087a8534b8914d062f`.
- Reported installed Dev app: 2.8.0 (3096), local source
  `05116ba494ad0c76638cca30e040bd798020e352`.
- The supplied installed-vs-GitHub patch is preserved: correction panel explicit
  NSHostingView sizing, StepFun terminal error semantics, and batch validation
  reporting configuration checks separately from a real connection check.
- Historical cases span multiple sessions/builds; do not attribute every case
  to the currently installed binary. No claim that the user's Mac was updated.

## Independently established findings

1. The provided records include two final Chinese corrections rejected at the
   strict affinity gate. The existing Han evaluator accepts only identical
   normalized pinyin; a `shen`/`sheng` difference is enough to reject the pair.
   Intermediate deletion was followed by a later affinity rejection in one
   case, so deletion did not terminate that particular observation.
2. A final-string diff loses the extent of a selected/retyped word when its
   unchanged characters disappear from the minimal diff. Asking the user to
   retype four characters cannot fix that alone. The coordinator previously
   observed values and destruction, not selected-text changes.
3. A separate source-level race exists: the four-second presentation timer
   can run before asynchronous candidate analysis completes. Staging a late
   result did not schedule presentation. The old logs do not prove that this
   race caused any specific historical miss.
4. `staged`, `presented`, `ignored`, and `saved` are different events. Earlier
   `ignored` logs do not distinguish user dismissal from panel timeout. A saved
   mapping is not disproved by an empty app-scoped-reference file.

## Implementation limits

- Keep `CorrectionAffinityAnalyzer` and batch acceptance unchanged. Immediate
  confirmation alone gains syllable-aligned `n/l`, `an/ang`, `en/eng`, `in/ing`
  alternatives, limited to equal-length 2–8 Han-character terms and at most one
  confused syllable for length 2–3, two for longer terms. No general relaxed
  edit-distance threshold or generated fuzzy dictionary is introduced.
- Use a selected UTF-16 range, projected into the original visible injection,
  or a directly observed contiguous deletion extent. Prefix/suffix outside
  that extent must remain exact. The observed extent resolves a single-Han-
  character ambiguity; it does not bypass factual, sensitive or unrelated-edit
  safeguards. Missing selection support retains the old text-diff fallback.
- A clear/reset gets a fixed four-second grace only when a prior compact-term
  selection or progressive deletion supports it and the same AX field remains
  focused. IME updates do not extend that deadline. Only an evidenced plausible
  replacement, or undo to the original, resumes observation. Unqualified sends
  and unrelated subsequent messages do not become correction candidates.
- Quiet-period expiry and analysis completion meet at a revisioned gate.
  Either may arrive first; cancellation, edits, ambiguous snapshots, setting
  changes and A→B→A stale results cannot reuse an earlier revision. Re-read the
  editor before displaying a candidate. A transient failed read restarts the
  quiet-period work after recovery instead of reusing potentially stale text.
- Discovery does not save anything. Default confirmation still writes a
  hotword plus an app-scoped soft reference. Forced global mapping remains a
  separate explicit user choice. Existing mappings and storage namespaces are
  not migrated, reset, or silently rewritten.
- Diagnostic events now distinguish `presented` from `staged`, and log the
  observation end reason by record ID without adding raw editor text to logs.

## Validation and acceptance boundaries

`CorrectionDiscoveryRegressionTests` covers the reported pronunciation failure,
other bounded confusion families, unrelated negatives, explicit word extents,
UTF-16/sentinel projection, repeated terms, deletion/undo sequences, unqualified
clear protection, both analysis/timer orderings, stale revisions and persistence
scope. Existing tests also cover the installed-only fixes.

A macOS native offline test run and compile-only Dev packaging are required
before accepting the branch. A Swift parser check and Linux Foundation phonetic
smoke test are preliminary checks, not substitutes for that run. CI evidence
records the actual candidate SHA, toolchain, source manifest and test logs.

CI uses isolated temporary homes and does not access the user's real history,
hotwords, credentials or microphone. An ad-hoc signed CI app is **compile-only**:
do not install it over the installed Dev app, change its data namespace, or
claim its signature is the user's trusted local signing identity.

Real editor acceptance still requires the user's Mac and installed identity:

1. In the actual target editor, dictate a phrase containing a misrecognized
   multi-character name, select the whole term, and type its preferred spelling.
   Check the offered pair and default soft-reference scope after the quiet period.
2. Repeat with contiguous backspace or forward-delete, including a transient
   empty field; finish retyping within the bounded grace period.
3. Test a four-character term with only one different final character, both
   with a full-term selection and without boundary evidence. The latter is
   allowed to abstain; the former should show the whole observed term.
4. Send/clear and type an unrelated next message, undo an edit, change a number
   or negation, and disable correction detection. None should create a new
   unintended learned mapping.

AX notifications can be unsupported/coalesced. If a browser/IME hides both the
pre-edit selection and intermediate deletion, final text alone cannot recover
an unobserved whole-word boundary. No keyboard logger, clipboard capture or
broad screen monitoring was added to make an unsupported guarantee.
