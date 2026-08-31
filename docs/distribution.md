# Distributing TotalRec outside the Mac App Store

TotalRec is distributed as a universal, Developer ID-signed and Apple-notarized
disk image. Do not send recipients an app from Xcode's Derived Data directory:
development and unsigned builds are not stable distribution identities and will
trigger Gatekeeper or Keychain trust problems.

## One-time setup

1. Join the Apple Developer Program and confirm that team `HL3W54MB57` is visible
   under **Xcode > Settings > Accounts**.
2. Select the team, open **Manage Certificates**, and create or import a
   **Developer ID Application** certificate. The private key must be present in
   the login Keychain on the Mac that creates releases.
3. Create an app-specific password for the Apple ID used for notarization.
4. Store the notarization credentials in Keychain. Omitting `--password` keeps the
   password out of the shell command and prompts securely:

   ```sh
   xcrun notarytool store-credentials TotalRec-notary \
     --apple-id 'developer@example.com' \
     --team-id HL3W54MB57
   ```

   An App Store Connect API key can be used instead; run
   `xcrun notarytool store-credentials --help` for the key options. Never commit
   an API private key, Apple ID password, or exported signing identity.

## Build a release

Set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the TotalRec target to
the values intended for the release, commit the release state, and run:

```sh
scripts/release.sh --preflight
scripts/release.sh
```

If the same version/build was already packaged, inspect it before deliberately
replacing it with:

```sh
scripts/release.sh --clean
```

The script:

1. Requires the correct Developer ID certificate and local Apple toolchain.
2. Archives a Release build for both `arm64` and `x86_64`.
3. Exports and verifies the Developer ID signature and Hardened Runtime.
4. Creates and signs a drag-to-Applications DMG.
5. Submits it with `notarytool`, waits for acceptance, staples the ticket, and
   runs Gatekeeper validation.
6. Writes the DMG and a SHA-256 checksum under `dist/`.

There is intentionally no skip-notarization mode: anything the script reports
as ready is suitable for distribution rather than merely suitable for local QA.

## Clean-Mac acceptance test

Test every release on a Mac/user account that has not run its development build:

1. Transfer the DMG through the same route recipients will use, preferably an
   HTTPS browser download so macOS applies quarantine metadata.
2. Open the DMG, drag TotalRec to Applications, and launch it normally.
3. Confirm Gatekeeper opens it without an unidentified-developer override.
4. Grant Microphone and Screen & System Audio Recording when prompted.
5. Configure the TScript server and any API keys. These settings and Keychain
   secrets are intentionally per Mac and are never embedded in the app.
6. Complete a short recording, transcription, playback, persistence, and relaunch
   smoke test.

The deployment target is macOS 14. Intel and Apple Silicon are both included in
the release image. If either architecture is missing, the release script fails.

## Useful diagnostics

```sh
codesign --verify --deep --strict --verbose=2 /Applications/TotalRec.app
spctl --assess --type execute --verbose=2 /Applications/TotalRec.app
xcrun stapler validate TotalRec-1.0.dmg
shasum -a 256 -c TotalRec-1.0.dmg.sha256
```

Apple references:

- [Developer ID](https://developer.apple.com/support/developer-id/)
- [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
