# wispr-free

A personal, on-device iOS dictation keyboard (not for the App Store). The main app holds the
microphone and runs Parakeet TDT v3 through [FluidAudio](https://github.com/FluidInference/FluidAudio)
on the Neural Engine. A keyboard extension signals it over an App Group plus Darwin notifications and
inserts the text.

## How it works

- **First mic tap:** the keyboard opens WisprFree, which starts a session and begins recording. Swipe
  right along the bottom edge to get back to your app, keep talking, and tap stop on the keyboard.
- **During a session:** the mic stays on (orange dot) so later taps record without leaving your app.
  Between dictations the app keeps only the last 0.4 s of audio in memory, as a lead-in for the next
  tap; nothing is transcribed or saved until you tap the mic.
- **Auto-stop:** the session ends after a set time without a dictation: 5 min by default, adjustable
  from 1 to 30 min in the app. After that, the next tap opens the app again.

Code: `App/WisprFree` (app), `App/Keyboard` (extension), `App/Shared/SharedIPC.swift` (the IPC contract).

## Build and install

Requires Xcode, a paid Apple Developer team (for the App Group) and XcodeGen (`brew install xcodegen`).
The `.xcodeproj` is generated and not committed.

```bash
scripts/app.sh team <TEAM_ID>   # once, after signing in to Xcode
scripts/app.sh build
scripts/app.sh install
scripts/app.sh log 100          # shared app + keyboard debug log
```

On the phone: Settings → General → Keyboard → Keyboards → Add New Keyboard → WisprFree, then turn on
**Allow Full Access** (needed to reach the App Group and to open the app).

Launch with `scripts/app.sh launch`, or from the home screen. Don't use the Xcode debugger
when testing background behaviour, because it keeps the app from being suspended.

## Platform constraints

- **Mic must stay on.** iOS keeps the app alive only while its audio engine runs; pausing the engine
  got it suspended within seconds, and recording can't be restarted from the background.
- **No way back to the host app.** Since iOS 26.4 there's no "◀ host app" breadcrumb after a
  keyboard-initiated open, and no API to return
  ([forum thread](https://developer.apple.com/forums/thread/826851)), so the app teaches the swipe.
- **Opening the app** uses the responder chain to reach `UIApplication.open`, which Apple DTS suggests
  for keyboards ([thread](https://developer.apple.com/forums/thread/812091)) but doesn't support.
- **iOS 27** seed reports say background Neural Engine inference broke there; the app falls back to
  the CPU if it fails. Untested on iOS 27.

## Phase 0 findings (background probe, since removed)

Measured on an iPhone 17 Pro running iOS 26.7.2, using FluidAudio 0.18.3 and Parakeet TDT v3 with
the app backgrounded and an active `playAndRecord` session:

| | Neural Engine | CPU |
|---|---|---|
| 3.4 s clip | 53–72 ms | 111–120 ms |
| 20.6 s clip | 185–263 ms | 285–291 ms |
| Model load | 0.13 s (cached) | 3.8 s |
| Peak memory | 70 MB | 88 MB |

Both had 0% WER on the test clips, and live mic transcription worked in the background. The probe's
code is in git history (last at commit `dba6472`).
