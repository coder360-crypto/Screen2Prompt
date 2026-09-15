# AGENTS.md

Notes for coding agents (and humans) working in this repo.

## What this is

A macOS menu bar app. You press `⌥R`, talk while you work, press `⌥C`
each time a screen matters, press `⌥R` again. It writes a folder of documents and puts
one self-contained card per step on the clipboard.

There is no server, no account, and no network call unless the user explicitly selects
the Groq provider.

## Layout

```
app/
  Package.swift              SwiftPM, macOS 26, executable target
  build.sh                   builds + hand-assembles + ad-hoc signs Screen2Prompt.app
  tools/make-icon.swift      renders AppIcon.icns from the Signal mark
  Sources/Screen2Prompt/
    main.swift               CLI flags, then NSApplication
    AppDelegate.swift        status item, menu, hotkeys, permission gate
    Session.swift            orchestrates a recording; owns the clipboard payload
    Capture.swift            ScreenCaptureKit grab + the burned-in STEP badge
    Audio.swift              AVAudioEngine -> 16 kHz mono Int16 -> session.raw, WAV header
    Transcribe.swift         Apple SpeechAnalyzer, whole-file
    Transcribers.swift       the Transcriber protocol + Apple / Groq / whisper.cpp
    Config.swift             ~/.screen2prompt/config.json + keychain for the Groq key
    DocBuilder.swift         step assignment by timestamp, markdown renderers
    Sheet.swift              composes the per-step cards
    Glyph.swift              the menu bar icon, drawn in code
    HotKeys.swift            Carbon RegisterEventHotKey
    Log.swift                appends to ~/Screen2Prompt/debug.log
design/                      identity artboards (.dc.html) — the logo and icon system
probe/                       standalone SpeechAnalyzer probe, for verifying the STT path
```

## Build and verify

```bash
cd app && ./build.sh
```

**There is a self-test. Use it — do not ask a human to try the app for you.**

```bash
pkill -f Screen2Prompt; rm -f ~/Screen2Prompt/debug.log
app/Screen2Prompt.app/Contents/MacOS/Screen2Prompt --selftest
cat ~/Screen2Prompt/debug.log
```

It runs a whole session end to end: start, two captures, stop, transcribe, build the
documents, write the clipboard, quit. Check `debug.log` for `mark: OK`,
`clipboard: N card files` and `session: done steps=N`.

## Things that will bite you

- **Launching matters for permissions.** Run the binary from a terminal and TCC
  attributes Screen Recording to the *terminal*, which usually already has it — so
  captures succeed and you conclude everything works. Launched from Finder the app
  needs its own grant. Test both, or you will ship something that silently captures
  nothing.
- **Every rebuild invalidates the Screen Recording grant.** The app is ad-hoc signed,
  so its code identity changes on each build and macOS orphans the TCC entry. If
  captures suddenly fail after a rebuild, that is why:
  `tccutil reset ScreenCapture co.ema.screen2prompt`, then relaunch and re-grant.
- **`steps: 0` means every capture failed.** All narration then lands in Closing notes,
  because there are no steps to attach words to. Check `debug.log` before theorising.
- **Do not put both text and image data on the pasteboard and expect both to survive.**
  A paste delivers one kind of content; chat boxes pick images and discard text.
  Several images arrive as several attachments *only* as file URLs — as raw image data
  they collapse to one. This is why narration is drawn into the cards.
- **`NSPasteboard` inspection via AppleScript lies.** `clipboard info` reports only the
  first item. Read `NSPasteboard.general.pasteboardItems` from Swift instead.
- **Audio position, not wall clock.** A marker's timestamp comes from
  `bytesWritten / 32000`, so it cannot drift from the audio it indexes into.

## Conventions

- Keep `DocBuilder`, `Sheet` and `Transcribers` free of AppKit-specific session state;
  they are the portable part.
- New transcription engines implement `Transcriber` (two members) and get selected in
  `Transcribers.make(_:)`. Nothing else should need to change.
- Secrets go in the keychain via `Config.swift`. Never in `config.json`, never in a log.
- Errors the user must act on get an `NSAlert`, not a line in a menu nobody opens.

## Status

The Apple on-device path is exercised and working. **The Groq and whisper.cpp providers
are written but untested end to end** — they compile and are wired in, but no real
request has been made through either. Treat them as a starting point.
