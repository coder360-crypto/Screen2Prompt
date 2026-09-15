#!/bin/bash
# Screen2Prompt — on-device transcription probe.
# Usage:  ./try-it.sh            record 20s from your mic, then transcribe
#         ./try-it.sh 30         record 30s
#         ./try-it.sh file X.wav transcribe an existing audio file
set -e
cd "$(dirname "$0")"

if [ ! -x .build/release/SpeechProbe ]; then
  echo "building (first run only, ~20s)..."
  swift build -c release --product SpeechProbe
fi

if [ "$1" = "file" ]; then
  exec ./.build/release/SpeechProbe "$2" "${3:-en-US}"
fi

SECS="${1:-20}"
echo
echo "  About to record ${SECS}s from your default microphone."
echo "  macOS will ask for Microphone access the first time — allow it."
echo "  Nothing leaves your machine: no API key, no network call."
echo
read -r -p "  Press Return when you're ready to talk... " _
exec ./.build/release/SpeechProbe record "$SECS" "${2:-en-US}"
