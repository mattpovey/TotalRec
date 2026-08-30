# Application review — 29 August 2026

## Summary

TotalRec has a coherent Capture → Transcript → Insights workflow, a capable transcript editor, and a consistent macOS visual language. The review initially identified recording reliability and recovery as the main release risk; the improvement plan below now addresses that risk and the subsequent usability findings.

The live review covered Capture, Transcript, Insights, session navigation, the configured TScript workflow, persistence and error paths, settings structure, and automated test coverage.

## Strengths

- The three-stage workflow is easy to understand.
- Transcript clips, timestamps, speaker cleanup, playback, document mode, and exports form a credible editing environment.
- Session-per-directory persistence with separate manifests and summaries is a sound recoverability foundation.
- Provider and model readiness are communicated clearly.
- TScript model discovery and transcription work against the configured private server.
- Insecure transport overrides are visible and accompanied by warnings.
- The interface uses consistent cards, typography, colors, and native macOS controls.
- Automated tests cover transcript transformations, playback, insight generation, streaming response parsing, and persistence.

## Prioritized findings

### P1 — Failed recording recovery

A failed session can display `Raw capture: capture.mov` solely because the filename is present in the session manifest. The reviewed failed capture was a zero-byte file without valid media metadata. Stop errors can also fall back to generic `NSError` descriptions and the UI offers no retry or recovery action.

Required outcomes:

- Validate that captures exist, are non-empty, and contain audio before finalization.
- Give distinct, actionable messages for missing, empty, unreadable, and audio-less captures.
- Allow a failed but plausible raw capture to retry mixdown.
- Allow users to reveal the session folder for manual inspection.
- Never describe an empty or missing file as a usable raw capture.
- Add focused lifecycle and recovery tests.

Status: addressed in the recording-recovery slice. Capture validation now distinguishes missing, empty, unreadable, audio-less, failed-mixdown, and invalid-output states; failed candidate captures can retry finalization, Session Details can reveal the stored files, and focused lifecycle tests cover inspection, validation, retry success, retry failure, and stop failure.

### P1 — Capture action placement

The main Capture pane describes recording and import, but its action card contains export actions. Start Recording and Import Audio live only in the sidebar. Put the primary capture/import actions in the main working context and reveal export actions once artifacts exist.

Status: addressed in the current Capture hierarchy slice. The main workspace now leads with recording, import, and fresh-session actions; export controls appear in a separate card only when audio or transcript artifacts exist.

### P1 — Stable session history

Clipboard confirmations are persisted as session status changes. Every status mutation updates `updatedAt`, and recent sessions are sorted by that field. A minor action such as Copy Transcript can therefore move a session and replace its meaningful workflow status. Use transient notifications for ephemeral feedback and reserve modification time for material changes.

Status: addressed in the current session-history slice. UI confirmations, validation warnings, and settings failures now use in-memory, auto-dismissing notices; durable session status and `updatedAt` remain reserved for workflow and artifact changes.

### P2 — Readiness hierarchy

Large readiness grids repeat information and visually outweigh the next action. Replace them with a compact readiness strip or progressive status summary.

Status: addressed in the current Capture hierarchy slice. Capture, Transcript, and Insights now show compact readiness chips, with supporting explanations available progressively through an expandable details section.

### P2 — Transcript density

Find and Replace is always expanded, repeated speaker identity is noisy, and the empty inspector consumes substantial space. Collapse secondary tools by default, automatically select a useful first item, and make the inspector resizable or collapsible.

Status: addressed in the current transcript workspace slice. Find and Replace is collapsed by default, adjacent clips no longer repeat unchanged speaker identity, the first visible clip is selected automatically, and the existing resizable inspector can now be hidden or restored.

### P2 — Sidebar scanning

Long source names truncate while status text and pills repeat similar information. Support editable session titles and reduce each row to one primary status plus a compact artifact summary.

Status: addressed in the current transcript workspace slice. Sessions now retain source provenance while supporting a separate editable title, and sidebar rows show one workflow status with a single compact artifact summary instead of repeated status text and pills.

### P2 — Pre-transcription audio confidence

A successfully finalized recording can be saved or sent to transcription, but the app does not expose an audio preview until timed transcript clips exist. Add a compact play/pause control to Capture or the Transcript Run step so users can confirm the recording before committing to transcription.

Status: addressed in the current playback slice with shared Capture and Transcript Run controls, seeking, elapsed time, invalid-file messaging, and automatic reset when the active session changes.

### P2 — Settings organization

The settings content is clear and transport warnings are strong, but provider credentials, model catalogs, insight defaults, name suggestions, and TScript configuration form a long single scroll. Group them into provider, transcription, and insights categories as the product grows.

Status: addressed in the current Settings organization slice. Native macOS preference tabs now separate provider credentials and model catalogs, transcription and speaker-name configuration, and insight defaults while preserving the existing shared persistence behavior.

### P1 — Repeated Keychain authorization prompts during testing

SwiftUI view initialization and configuration-change notifications can request both API keys repeatedly. Interactive use of an unsigned QA build can compound the issue because macOS cannot durably associate “Allow Always” with a stable signing requirement.

Status: addressed in the Keychain-access slice. Credential lookups—including missing or unavailable credentials—are cached once per account for the app process, successful changes refresh the cache, and no-op changes skip Keychain writes and configuration broadcasts. Regression tests cover successful, missing, and replaced cached values. Developer guidance now distinguishes unsigned CI tests from normally signed interactive QA builds.

## Recommended sequence

1. Harden recorder finalization and failed-capture recovery.
2. Separate persistent workflow state from transient notifications and stabilize session ordering.
3. Move capture/import actions into the Capture workspace and simplify readiness presentation.
4. Improve transcript density and session naming.
5. Reorganize Settings after the core workflow is stable.
6. Bound Keychain access and keep interactive QA builds consistently signed.

## Completion verification — 30 August 2026

- All nine prioritized findings above have an implemented and source-audited resolution.
- The complete unsigned macOS Release configuration builds successfully.
- The full Xcode test suite passes 60 tests, including focused coverage for bounded Keychain access, recording recovery, session-status stability, title persistence, audio playback, transcript playback selection, settings categorization, insight persistence and cancellation, transcript transformations, and transport parsing.
- `git diff --check` reports no whitespace errors, and the changed implementation surfaces contain no unresolved `TODO`, `FIXME`, `HACK`, or `fatalError` markers.
