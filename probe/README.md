# Screen2Prompt — transcription probe

Proves macOS 26's on-device `SpeechAnalyzer` works before we build the app around it.
No API key, no network, no permissions except the microphone (only for `record` mode).

    ./try-it.sh              # record 20s from your mic, then transcribe
    ./try-it.sh 45           # record 45s
    ./try-it.sh file audio/long.wav      # transcribe a file instead
    ./try-it.sh file audio/silence.wav   # 12s of digital silence -> 0 results

`record` mode runs the real pipeline from SPEC.md:
mic -> downmix to mono -> resample to 16 kHz Int16 -> `audio/session.raw` (§5.1, §5.2)
-> hand-written 44-byte WAV header (§5.3) -> on-device transcription.

It prints the transcript, per-word timestamps and per-word confidence.
