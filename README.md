# wispr-free

A personal, on-device iOS dictation keyboard (not for the App Store). The main app holds the
microphone and runs Parakeet TDT v3 through [FluidAudio](https://github.com/FluidInference/FluidAudio)
on the Neural Engine. A keyboard extension signals it over an App Group plus Darwin notifications and
inserts the text.

## Status: phase 0, the background probe

`Prototype/BackgroundProbe` is a throwaway app that answers one question: **can the app transcribe with
Parakeet while backgrounded, with only an active audio session keeping it alive?** It runs on the
Neural Engine, on the CPU, or on the GPU as a control (the GPU is expected to fail in the background).

One run:

1. Downloads the models on first launch (about 0.5 GB), loads them on the chosen compute units, and
   benchmarks two bundled clips (3.4 s and 20.6 s of `say` speech with known text) in the foreground.
2. Starts the mic (`playAndRecord` + `mixWithOthers`) and waits for you to go home or lock the phone.
3. In the background, re-runs the benchmark at +3 s, 1, 3, 5 and 6 min, and transcribes the last
   5 s of live mic audio every 10 s. A 1 s heartbeat detects whether iOS suspended the process.
4. Optionally unloads and reloads the models while backgrounded, then pauses the mic engine for 20 s
   and tries to restart it from the background.
5. Logs latency, RTFx, WER, `phys_footprint` and `os_proc_available_memory` to
   `Documents/probe-<mode>-<time>.log` (also visible in the Files app), followed by a summary table.

```bash
scripts/probe.sh team <TEAM_ID>   # once, after signing in to Xcode
scripts/probe.sh build
scripts/probe.sh install
scripts/probe.sh run ANE 6        # then swipe home and talk; come back after 6 min
scripts/probe.sh pull             # logs land in results/
```

Requires XcodeGen (`brew install xcodegen`); the `.xcodeproj` is generated and not committed.
