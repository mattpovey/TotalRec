// TotalRec

// TotalRec is a macOS app that records system audio + microphone, mixes them, and transcribes the result using Apple Speech or OpenAI with diarization.

// Security of Secrets (OpenAI API Key)
// - The OpenAI API key is stored securely in the system Keychain, not in the repository or project files.
// - On first launch after this change, any legacy key previously saved in the JSON config is migrated automatically to Keychain and removed from disk.
// - Because the key lives in Keychain (e.g., `~/Library/Keychains/...`), it is never picked up by Git and won’t be pushed to GitHub.

// Where configuration lives
// - Non-secret configuration (like default provider) is stored in `~/Library/Application Support/<BundleID>/AIConfiguration.json`.
// - Secrets (OpenAI key) are stored in Keychain under the service `com.totalrec.ai` and account `openai_api_key`.

// Using the App
// 1. Choose a transcription provider (Apple On-Device, Apple Cloud, or OpenAI) from the UI.
// 2. If you choose OpenAI, enter your API key in Settings (gear icon). It will be saved to Keychain.
// 3. Record, stop, and transcribe.

// Git and Remotes
// If you’re pushing this project to GitHub:
// - Initialize the repo and set a remote:
//   ```bash
//   git init
//   git remote add origin <ssh-or-https-url>
//   git add .
//   git commit -m "Initial commit"
//   git branch -M main
//   git push -u origin main
//   ```
// - Secrets are not in the repo; no additional ignore rules are needed for the OpenAI key.

// Large Audio Files (Optional)
// If you plan to version audio, consider Git LFS:
// ```bash
// brew install git-lfs
// git lfs install
// git lfs track "*.m4a" "*.mp3" "*.wav" "*.aac"
// git add .gitattributes
// git commit -m "Track audio files with Git LFS"
// ```

// Troubleshooting
// - Keychain access test: `AIConfigManager.keychainSelfTest()` performs a simple add/read/delete cycle and returns an error if Keychain isn’t usable.
// - If OpenAI requests fail with `missing API key`, verify you’ve entered the key in Settings and that the app can access Keychain (first run prompts, keychain locked, etc.).

// License
// MIT
