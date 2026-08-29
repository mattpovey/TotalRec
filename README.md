# TotalRec

TotalRec is a macOS app for recording system audio and microphone input, transcribing the result locally or through a configured service, and generating reusable transcript-derived artifacts. It streamlines capture → transcript → insights while keeping sessions recoverable between launches.

## Features
- Record mixed audio (system + microphone) to a single M4A file
- Import existing audio from disk or by URL
- Transcribe with:
  - Apple Speech (on-device or cloud)
  - OpenAI diarized transcription (with optional Known Speakers)
  - TScript servers with model discovery, timestamps, translation, and optional diarization
- Review transcript segments, correct wording, find and replace text, and play timed clips
- Reassign, merge, and label speakers; request name suggestions from OpenAI or SambaNova
- Generate meeting notes, action lists, decision logs, customer-call summaries, podcast summaries, or custom artifacts
- Export audio, transcripts (`.txt`, `.json`, `.vtt`, `.srt`), and insights (`.txt`, `.json`)
- Resume, inspect, switch, and delete persisted recording sessions
- Start and stop recording from the menu bar

## App Workflow
The app is organized in three tabs:

1. Capture
   - Start/stop recording system audio + mic
   - Import audio from file or URL
   - Save mixed audio
   - Quick preview of the latest transcript (if available)
2. Transcript
   - Run transcription with Apple, OpenAI, or TScript
   - Correct transcript text and apply literal replacements
   - Play individual timed segments or surrounding context
   - Manage speaker aliases and assignments, merge speakers, and consolidate consecutive turns
   - Preview/copy the final document and export Plain Text, JSON, WebVTT, or SubRip
3. Insights
   - Choose a built-in workflow or supply a custom prompt
   - Stream generation through OpenAI Responses or SambaNova-compatible chat completions
   - Stop an in-progress generation without replacing the last saved artifact
   - Export or copy the generated artifact

## Requirements

- Xcode 26.1+ (tested with Xcode 26.6)
- macOS 14+
- An OpenAI API key for OpenAI transcription, OpenAI insights, or OpenAI name suggestions
- A SambaNova API key for SambaNova insights or name suggestions
- A reachable TScript server for TScript transcription

## Build & Run
1. Open the project in Xcode.
2. Select the shared `TotalRec` scheme and run.
3. On first record, macOS will request Screen Recording permission. Grant it in:
   - System Settings → Privacy & Security → Screen Recording → enable for this app
4. Configure the providers you want to use in Settings.

Run the complete unit-test suite from the command line with:

```sh
xcodebuild test \
  -project TotalRec.xcodeproj \
  -scheme TotalRec \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

GitHub Actions runs the same build and test flow on the `macos-26` runner.

## Configuration
### Transcription Provider
Choose between:
- Apple (On-Device)
- Apple (Cloud)
- OpenAI (Diarized)
- TScript

The current provider is shown with a readiness summary. OpenAI requires a Keychain-backed API key. TScript requires a server URL and discovers the available models and capabilities from that server.

### Insight and Name-Suggestion Providers

- OpenAI uses the Responses API for insight generation.
- SambaNova uses an OpenAI-compatible chat-completions transport.
- Provider model lists can be refreshed in Settings and are cached locally.
- API keys are stored in Keychain; non-secret provider settings are stored in Application Support.

### OpenAI Key & Upload Chunking
- Enter your OpenAI API key in the app’s Settings window. It’s stored in Keychain.
- Upload chunking for long audio:
  - `Auto` (default): Splits long audio into multiple uploads
  - `Single Upload`: Uploads the entire file at once and may fail for very large recordings

### Known Speakers (Optional)
Provide up to 4 known speakers to improve diarization with OpenAI. Each entry requires both:
- Name
- Reference (either a `data:audio/...` URL or a local file path)

If any row is partially filled, transcription with OpenAI will be disabled until the row is completed or cleared.

This is useful if transcribing known speakers repeatedly but in general the Suggest Names functionality works well enough for this purpose if names are mentioned in the transcript (i.e. when people introduce themselves)

### Name Suggestions Provider
Controls where speaker name suggestions come from and can be disabled. Name suggestions are enabled in the standard Debug and Release builds.

### TScript

Configure the server URL in Settings, then refresh its model registry. Per-model options include language, translation, timestamps, diarization, speaker-count hints, and supported advanced decoding controls. HTTPS is required by default; insecure HTTP and invalid-certificate overrides are explicit opt-ins for trusted development servers.

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
  - OpenAI: optionally splits long recordings into multiple uploads and supports known speakers
  - TScript: uploads to the selected server model and consumes structured timed/diarized output when available
- Request Suggestions: asks the configured provider for speaker name ideas
- Consolidate Consecutive Speakers: merges back-to-back turns by the same speaker
- Transcript editor: correct individual segments or raw text and apply literal replacements
- Playback: play timed clips and configurable surrounding context
- Export: save as .txt, .json, .vtt, or .srt

### Insights

- Select meeting notes, action items, decisions, customer call, podcast summary, or a custom workflow
- Custom Prompt: keep `{{TRANSCRIPT}}` where the formatted transcript should appear; if omitted, TotalRec appends the transcript
- Stream, stop, copy, and export insight artifacts as `.txt` or `.json`

## Permissions
- Screen Recording: required for capturing system audio
- Microphone: required for mic capture

If recording fails to start, check System Settings → Privacy & Security → Screen Recording and Microphone.

## Architecture Overview

- `TotalRecApp` owns the main window, Settings scene, and menu-bar extra.
- `AppModel` is the main-actor workflow coordinator and exposes the active/recent session state.
- `SessionStore` persists session manifests, summaries, audio, transcripts, and insight artifacts under Application Support.
- Recording runs through `SystemAudioRecorder` → temporary MOV → `Mixdown.toM4A` with adjustable gains.
- Transcription
  - Apple: `FileTranscriber.transcribeFile(onDevicePreferred:)` with streaming partials
  - OpenAI: `OpenAITranscriber.transcribeDiarized` with optional chunking and known speakers
  - TScript: `TScriptTranscriber` with server model discovery and capability-aware requests
- `TranscriptState` is the canonical editable transcript model; transcript feature views handle editing, speakers, document output, and playback.
- `InsightGenerationService` renders workflow prompts and selects the OpenAI Responses or conversation transport.
- `AIConfigManager` persists provider settings and Keychain credentials; `DiagnosticsLogger` writes insight diagnostics under Application Support.
- The UI uses native glass effects on macOS 26 and static surface fallbacks on macOS 14–15.

## Troubleshooting
- “Screen capture permission required”: Grant Screen Recording permission and retry.
- OpenAI transcription disabled: Ensure API key is set and no partially filled Known Speakers rows remain.
- Long audio: Try `Auto` chunking with OpenAI.
- TScript models unavailable: Verify the server URL, refresh models, and confirm the selected model is runtime-available.
- Insight generation disabled: Verify the selected provider has an API key and a compatible model.

## Roadmap

- Additional analytics and structured insight outputs
- More transcription and LLM providers
- Broader integration and UI automation coverage

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
