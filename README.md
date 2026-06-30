# TONGUES — iOS App

An AI-powered language-learning app (SwiftUI, iOS 26).

## Setup

The app needs two local config files that are **not** committed (they hold
keys). After cloning:

1. **API keys** — copy the template and fill in your keys:
   ```sh
   cp Secrets.example.plist Secrets.plist
   ```
   Then edit `Secrets.plist` and provide:
   - `ANTHROPIC_API_KEY`
   - `ELEVENLABS_API_KEY`
   - `FORVO_API_KEY`
   - `SUPADATA_API_KEY`

   These are read at runtime by `Services/Secrets.swift`.

2. **Firebase** — add your own `GoogleService-Info.plist` to `TONGUES/`
   (download it from the Firebase console for your project).

Both files are listed in `.gitignore`.

> ⚠️ **Note on client-side keys:** keys bundled in an iOS app can be
> extracted from the IPA — they are not truly secret. For production,
> proxy third-party APIs through your own backend so the real keys never
> leave the server. The `Secrets.plist` mechanism only keeps keys out of
> the git repository.

## Build

Open `TONGUES.xcodeproj` in Xcode and run the `TONGUES` scheme.
