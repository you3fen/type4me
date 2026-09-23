# Personal Dev 2.9.0

This update keeps the personal dictation branch and selectively ports five
changes present in upstream v2.9.0. It does not merge upstream main wholesale.

## Included changes

- LLM streams must reach their protocol completion marker before their text is
  treated as a successful response. Interrupted responses retain error usage
  accounting and follow the existing error/fallback path.
- Usage accounting records each request outcome once, avoids estimating or
  backfilling successful-response costs for failed historical requests, and
  refreshes the dashboard after pricing and historical recalculation finish.
- A cancelled streaming recording that never produced text does not replay all
  audio merely because its final event was missing. Normal stops, previously
  received text and transport/server errors preserve recovery.
- Dev logs, local ASR PID files and updater staging use the Dev runtime
  directory. User history, vocabulary, correction references, models and
  credentials keep their existing profile. Personal-only previews keep their
  isolated namespace; personal+Dev keeps the shared Type4Me profile.
- Packaged macOS permission descriptions have an English fallback and
  Simplified Chinese localization.

Upstream provenance: b627606d (#310 follow-up differences only), 911b0f69
(#305), cc56207b (#311), 13461d7c (#298), and 17001ca5 (directory URL assertion).

## Preserved behavior

Personal vocabulary, app-scoped correction references, guarded reuse,
immediate correction discovery and the StepFun error/configuration fixes
remain. Both personal compiler flags remain enabled for the installed Dev
app. Its bundle identifier, URL scheme, Keychain prefix and signing identity
remain unchanged; personal upstream-update blocking remains enabled.

Post-v2.9.0 features such as MiMo LLM, menu-bar LLM switching, StepFun region
selection and all-mode Voice Revise are intentionally outside this update.

## Validation boundaries

Run offline regression tests with a separate CFFIXED_USER_HOME and temporary
stores, denying model network access and access to real profile/Keychain files.
The existing KeychainServiceTests require native Keychain writes and are
excluded from this unattended offline run; namespace and signing continuity
are verified separately. Live Codex/model tests remain opt-in.

XCTest audio output is suppressed before warmup, Bluetooth primers and the
playback/beep fallback. This is compiled only in DEBUG test paths; normal app
sound preferences and release playback are unchanged.

Validate normal and interrupted LLM streams, usage outcomes, cancellation and
recovery, profile/runtime routing, personal correction/reference regression,
all four compile-flag namespace combinations, localization packaging, universal
architecture, signature and installed-bundle integrity. Actual microphone,
editor insertion and model quality require normal user acceptance.

Local validation on 2026-09-23: 1,302 XCTest cases completed with 2 opt-in live
cases skipped and zero failures; 5 Swift Testing cases passed. The native
KeychainServiceTests class was excluded for the secure-store boundary above.
All four independently compiled namespace combinations and permission bundle
packaging checks passed. After adding XCTest audio isolation, six targeted
stop/error cases passed and logged suppression instead of audio playback.
