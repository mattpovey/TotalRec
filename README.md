# TotalRec

TotalRec is a macOS app for recording system audio + microphone, transcribing the result with Apple or OpenAI, and generating structured meeting insights. It streamlines the workflow from capture → transcript → insights, with tools for speaker labeling and export.

> Note: This repository contains SwiftUI code targeting macOS. Some features (file panels, window sizing) are macOS-only.

## Features
- Record mixed audio (system + microphone) to a single M4A file
- Import existing audio from disk or by URL
- Transcribe with:
  - Apple Speech (on-device or cloud)
  - OpenAI diarized transcription (with optional Known Speakers)
- Review and edit transcripts with speaker tools
- Request speaker name suggestions (configurable provider)
- Generate structured meeting notes (with an optional custom prompt)
- Export audio, transcripts (.txt, .json, .vtt, .srt), and notes (.txt, .json)

## Screenshots
Add screenshots to the repository (e.g., in a `Screenshots/` folder) and update the image links below.

- Capture tab
  - ![Capture Tab Placeholder](Screenshots/capture.png)
- Transcript tab
  - ![Transcript Tab Placeholder](Screenshots/transcript.png)
- Insights tab
  - ![Insights Tab Placeholder](Screenshots/insights.png)
- Settings sheet
  - ![Settings Placeholder](Screenshots/settings.png)

## App Workflow
The app is organized in three tabs:

1. Capture
   - Start/stop recording system audio + mic
   - Import audio from file or URL
   - Save mixed audio
   - Quick preview of the latest transcript (if available)
2. Transcript
   - Run transcription (Apple on-device/cloud or OpenAI diarized)
   - Manage speaker labels and consolidate consecutive speaker turns
   - Request speaker name suggestions
   - Export transcript as Plain Text, JSON, WebVTT (.vtt), or SubRip (.srt)
3. Insights
   - Generate structured meeting notes from the transcript
   - Optionally use a custom prompt (keep `{{TRANSCRIPT}}` where the diarized text should be inserted)
   - Export notes as Plain Text or JSON

## Requirements
- Xcode 15+ (tested with Xcode 26.1 toolchain)
- macOS 13+
- Swift Concurrency enabled (Swift 5.9+)
- For OpenAI features: an OpenAI API key

## Build & Run
1. Open the project in Xcode.
2. Select the macOS target and run.
3. On first record, macOS will request Screen Recording permission. Grant it in:
   - System Settings → Privacy & Security → Screen Recording → enable for this app
4. (Optional) Configure OpenAI in Settings within the app.

## Configuration
### Transcription Provider
Choose between:
- Apple (On-Device)
- Apple (Cloud)
- OpenAI (Diarized)

The current provider is shown in the header with a status badge. For OpenAI, the badge indicates whether an API key is configured.

### OpenAI Key & Chunking
- Enter your OpenAI API key in the app’s Settings sheet. It’s stored securely in Keychain.
- Chunking strategy for long audio:
  - `Auto` (default): Splits long audio into multiple uploads
  - `None`: Uploads the entire file at once

### Known Speakers (Optional)
Provide up to 4 known speakers to improve diarization with OpenAI. Each entry requires both:
- Name
- Reference (either a `data:audio/...` URL or a remote URL)

If any row is partially filled, transcription with OpenAI will be disabled until the row is completed or cleared.

### Name Suggestions Provider
Controls where speaker name suggestions come from (can be disabled).

### Mixdown Gains
Adjust system and mic gain before mixing down the recorded MOV into M4A.

## Using the App
### Capture
- Start Recording: begins system + mic capture, writing a temporary MOV file that is mixed down to M4A
- Import Audio…: choose a local audio file or download from a URL
- Save Audio…: export the mixed M4A
- Save Transcript…: choose a format to export the current transcript

### Transcript
- Transcribe Audio: runs the selected provider
  - Apple: streams partial text to the UI
  - OpenAI: optionally uses chunking and known speakers
- Request Suggestions: asks the configured provider for speaker name ideas
- Consolidate Consecutive Speakers: merges back-to-back turns by the same speaker
- Export: save as .txt, .json, .vtt, or .srt

### Insights
- Generate Meeting Notes: produces a structured summary from the transcript
- Custom Prompt (optional): supply your own instructions; keep `{{TRANSCRIPT}}` where the diarized text should appear
- Export notes as .txt or .json

## Permissions
- Screen Recording: required for capturing system audio
- Microphone: required for mic capture

If recording fails to start, check System Settings → Privacy & Security → Screen Recording and Microphone.

## Architecture Overview
- SwiftUI view hierarchy anchored by `ContentView`
  - Tabs: Capture, Transcript, Insights
  - Settings presented as a sheet
- Recording via `SystemAudioRecorder` → temporary MOV → `Mixdown.toM4A` with adjustable gains
- Transcription
  - Apple: `FileTranscriber.transcribeFile(onDevicePreferred:)` with streaming partials
  - OpenAI: `OpenAITranscriber.transcribeDiarized` with optional chunking and known speakers
- Transcript state modeled by `TranscriptState`, rendered by `TranscriptView`
- Export via `TranscriptRenderer` for caption formats (WebVTT/SRT)
- Insights via `MeetingNotesService` (optional custom prompt)
- Config persisted with `AIConfigManager` (OpenAI key, provider choices)

## Troubleshooting
- “Screen capture permission required”: Grant Screen Recording permission and retry.
- OpenAI transcription disabled: Ensure API key is set and no partially filled Known Speakers rows remain.
- Long audio: Try `Auto` chunking with OpenAI.

## Roadmap
- Additional analytics in Insights
- More providers for transcription and name suggestions
- Cross-platform considerations where feasible

## License
Add your license here (e.g., MIT). Replace this section with the appropriate license text.
