# TotalRec

TotalRec is a macOS app that records system audio and microphone audio, mixes them into a single track, and provides transcription using either Apple Speech or OpenAI (with diarization support).

## Build Requirements
- macOS 14 or later
- Xcode 15 or later

## How to Build and Run
1. Open the project in Xcode (TotalRec.xcodeproj).
2. Select the "TotalRec" scheme and your Mac as the run destination.
3. Build and run (Cmd+R).

On first launch, the app will request Screen Recording permission (for capturing system audio). Grant permission in System Settings > Privacy & Security > Screen Recording if prompted.

## Notes
- Transcription can be performed with Apple Speech (on-device or cloud) or with OpenAI. If you choose OpenAI in the app's settings, provide your API key in the Settings sheet.
