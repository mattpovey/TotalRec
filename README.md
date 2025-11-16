# TotalRec

TotalRec is a macOS app for recording system audio + microphone, transcribing the result with Apple or OpenAI, and generating structured meeting notes or running an arbitrary LLM prompt against the transcript. It streamlines the workflow from capture → transcript → insights, with tools for speaker labeling and export.

## Features
- Record mixed audio (system + microphone) to a single M4A file
- Import existing audio from disk or by URL
- Transcribe with:
  - Apple Speech (on-device or cloud)
  - OpenAI diarized transcription (with optional Known Speakers)
- Review and edit transcripts with speaker tools
- Request speaker name suggestions from a LLM
- Generate structured meeting notes (or use an optional custom prompt)
- Export audio, transcripts (.txt, .json, .vtt, .srt), and notes (.txt, .json)

## Screenshots

- Capture tab
  - ![Capture Tab](Screenshots/capture.png)
- Transcript tab
  - ![Transcript Tab](Screenshots/transcript.png)
- Insights tab
  - ![Insights Tab](Screenshots/insights.png)
- Settings sheet
  - ![Settings](Screenshots/settings.png)

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
4. (Optional) Configure OpenAI API key in Settings within the app.

## Configuration
### Transcription Provider
Choose between:
- Apple (On-Device)
- Apple (Cloud)
- OpenAI (Diarized)

The current provider is shown in the header with a status badge. For OpenAI, the badge indicates whether an API key is configured.

### OpenAI Key & Chunking
- Enter your OpenAI API key in the app’s Settings sheet. It’s stored in Keychain.
- Chunking strategy for long audio:
  - `Auto` (default): Splits long audio into multiple uploads
  - `None`: Uploads the entire file at once but will fail if the audio is longer than permitted by the API

### Known Speakers (Optional)
Provide up to 4 known speakers to improve diarization with OpenAI. Each entry requires both:
- Name
- Reference (either a `data:audio/...` URL or a remote URL)

If any row is partially filled, transcription with OpenAI will be disabled until the row is completed or cleared.

This is useful if transcribing known speakers repeatedly but in general the Suggest Names functionality works well enough for this purpose if names are mentioned in the transcript (i.e. when people introduce themselves)

### Name Suggestions Provider
Controls where speaker name suggestions come from (can be disabled).

### Mixdown Gains
Adjust system and mic gain before mixing down the recorded MOV into M4A.

## Using the App
### Capture
- Start Recording: begins system + mic capture, writing a temporary MOV file that is mixed down to M4A
- Import Audio…: choose a local audio file or download from a URL
- Save Audio…: export the mixed (system output and mic) M4A
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
MIT License

Copyright (c) 2025 Matthew Povey

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
