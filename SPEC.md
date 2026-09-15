# ScreenDoc — Narrated Screen Capture → Markdown Prompt Document

**Status:** Draft spec v1
**Date:** 2026-09-15
**Target platforms:** macOS + Windows
**Owner:** Ashish Patwa

---

## 1. What this is

A desktop tool that sits in the tray. You press a hotkey to start, you talk while you work, and every time you press a second hotkey it grabs the screen at that instant. When you stop, you get a markdown document: screenshot, then what you said about it, step by step.

The output is designed to be handed to an AI agent as a prompt — "here is the problem, here are the screens, here is what I said about each one" — but it works equally well as a bug report, a walkthrough, or a handover note.

One sentence: **narrate your screen, get a document.**

### The whole thing, in three lines

Everything else in this document is detail underneath these. If a decision later in the spec makes one of these worse, the decision is wrong.

1. **One key starts and stops recording.**
2. **One key captures the screen.** Press it as many times as you like during a session.
3. **Both keys, and the Groq API key, are set by the user in a settings window.** No editing JSON, no environment variables, no rebuild.

That is the product. A session is: hit key 1, talk while you work, hit key 2 whenever a screen matters, hit key 1 again. A folder appears with a markdown document in it.

Ship exactly this in v1 and nothing else. §12 orders the rest.

---

## 1a. Design principles — the Maccy test

The reference point for how this should *feel* is [Maccy](https://maccy.app/), the macOS clipboard manager. Not what it does — how it behaves. Every design decision below should pass these:

1. **Lives in the menu bar. No dock icon, no main window.** The app is invisible until a hotkey summons it. There is no "open the app" step.
2. **Keyboard-first.** The mouse is optional for everything in the core loop. You should be able to run a whole session without seeing the UI once.
3. **Small and quiet.** Single-digit-MB binary, tens of MB of RAM, no background CPU when idle. It runs all day and you forget it is there.
4. **Instant.** Hotkey to screenshot-captured is imperceptible. Nothing spins, nothing loads.
5. **No account, no cloud sync, no telemetry.** Files on disk you own. One API key you supply, stored in the OS keychain.
6. **Does one thing.** Resist the settings panel. Every option in §11 has to earn its place.

**This constrains the stack, and it is in direct tension with the cross-platform requirement.** Maccy feels like Maccy substantially *because* it is native Swift and Mac-only. §4.1 works through the trade honestly — but the short version is that Electron fails principle 3 outright at ~150MB of binary and ~120MB of idle RAM, so it is off the table.

---

## 2. The core insight

The expensive part of "understand a screen recording" is normally segmentation — deciding which frames matter and which words go with which frame. That is what would otherwise need vision models, scene-change detection, or OCR.

**The marker keypress removes all of it.** You are telling the tool, with your own hands, exactly which screen matters and exactly when. There is no inference to do.

So: **no ML anywhere in the visual pipeline.** No OCR, no frame diffing, no scene detection, no vision model. Screenshots are taken, not chosen.

The only ML in the system is speech-to-text, and that is a hosted API call (or a local binary). You are not building, training, or tuning a model.

---

## 3. The recording model

This is the heart of the spec. Everything else is plumbing.

### 3.1 The chunk contract

```
Session start (t = 0)
  │
  │  audio records continuously to one raw PCM file
  │
  ├── T₁  marker pressed  →  screenshot₁ captured at exactly T₁
  │         chunk₁ = audio [ 0 , min(T₁ + TAIL, T₂) ]
  │
  ├── T₂  marker pressed  →  screenshot₂ captured at exactly T₂
  │         chunk₂ = audio [ end₁ , min(T₂ + TAIL, T₃) ]
  │
  ├── …
  │
  └── T_stop
```

Formally, for markers at `T₁ … T_k`:

| | |
|---|---|
| `screenshot_i` | captured synchronously at `T_i` |
| `end_i` | `min(T_i + TAIL, T_{i+1})` for `i < k`; `min(T_k + TAIL, T_stop)` for `i = k` |
| `start_i` | `0` for `i = 1`; `end_{i-1}` for `i > 1` |
| `chunk_i` | audio `[start_i − OVERLAP, end_i]`, clamped at 0 |
| **Step _i_ in the document** | `screenshot_i` + `transcribe(chunk_i)` |

**Defaults:** `TAIL = 5000ms`, `OVERLAP = 1000ms`.

### 3.2 Why the tail exists

People click and *then* explain. "Look at this dropdown — *[click]* — it's only showing two regions." Without the tail, that explanation lands in the next chunk and gets attached to the wrong screenshot.

Five seconds after the marker is the natural unit. If the next marker arrives before the tail expires, the chunk closes early — rapid clicking degrades gracefully rather than producing overlapping chunks.

### 3.3 Why the overlap exists

A chunk that begins mid-syllable makes Whisper produce garbage at the leading edge. One second of overlap with the previous chunk means every chunk starts on audio the model has already seen in context.

The duplicated word or two at the seam is removed by a **string-level dedupe**: compare the last 8 words of chunk `i−1` with the first 8 words of chunk `i`, find the longest matching run, drop it from chunk `i`. Plain string matching, no model.

A second, complementary fix: pass the last ~200 characters of chunk `i−1`'s transcript as the `prompt` parameter on chunk `i`'s request. This is a documented Whisper feature for exactly this case ("continue a previous audio segment") and materially improves boundary accuracy. Use both.

### 3.4 Everything after the last marker

Audio between `end_k` and `T_stop` is not dropped and is not appended to the last step. If it contains speech, it is emitted as a separate **"Closing notes"** section at the bottom of the document. If it is silence, it is discarded.

This stops the last step from absorbing five minutes of dead air when you forget to hit stop.

### 3.5 Why chunks, not one file

Closing the chunk at the marker instead of transcribing one long file at the end buys four things:

1. **No timestamp reconciliation at all.** Chunk `i` belongs to step `i`. There is no global clock to map back onto.
2. **Transcription happens during recording.** Each chunk is uploaded the moment it closes. By the time you press stop, the document is essentially written.
3. **The 25MB request cap stops existing.** A 90-second chunk is ~2.8MB as 16kHz mono WAV. Roughly 9× headroom even on long chunks.
4. **Failures are isolated.** One bad chunk retries on its own; it does not take the session with it.

---

## 4. Architecture

```
┌──────────────────────────────────────────────────────────┐
│ Rust core                                                 │
│                                                           │
│  HotkeyService      tauri-plugin-global-shortcut          │
│  SessionManager     owns session state + step list        │
│  AudioWriter        cpal stream → session.raw on disk     │
│  ScreenCapture      xcap → PNG                            │
│  ChunkScheduler     computes boundaries, emits chunks     │
│  TranscriptQueue    concurrency-limited Groq client       │
│  DocBuilder         session.json → doc.md                 │
└───────────────┬───────────────────────────────────────────┘
                │ Tauri commands / events
┌───────────────┴───────────────────────────────────────────┐
│ Webview (tray popover only — hidden by default)           │
│  recording state, step thumbnails, live transcript, prefs │
└───────────────────────────────────────────────────────────┘
```

Note what is *not* here: no hidden renderer doing work, no IPC in the hot path. The hotkey → screenshot → disk path is entirely Rust and never touches the webview. The webview exists only for the popover UI, and the app runs fine with it never opened (principle 2).

### 4.1 Stack recommendation

**Tauri v2 + Rust.**

The Maccy test rules out Electron — it fails principle 3 by an order of magnitude. That leaves two real options:

| | Tauri v2 | Swift (Mac-only) | ~~Electron~~ |
|---|---|---|---|
| Platforms | macOS + Windows | macOS only | macOS + Windows |
| Binary | ~10MB | ~5MB | ~150MB |
| RAM idle | ~40MB | ~25MB | ~120MB |
| Global hotkey | `tauri-plugin-global-shortcut` (official) | `RegisterEventHotKey` | `globalShortcut` |
| Screen capture | `xcap` crate | ScreenCaptureKit | `desktopCapturer` |
| Audio capture | `cpal` crate | AVAudioEngine | `getUserMedia` |
| VAD | `voice_activity_detector` crate (Silero/ort) | same, or Apple's | `@ricky0123/vad-web` |
| Free on-device STT | — | **`SpeechAnalyzer`** | — |
| Menu-bar-native feel | good | perfect | poor |

**Tauri is the recommendation**, because you asked for Windows and it is the only option that delivers both Windows and the Maccy footprint. The cost is real but bounded: audio capture and WAV encoding are hand-rolled in Rust rather than handed to you by Chromium, and the VAD crate is less trodden than the JS one. Call it a week of extra work against Electron, spread across Phases 1 and 2.

**But be honest with yourself about Windows.** If you would actually only ever run this on your own Mac, Swift is the better answer and it is not close:

- ScreenCaptureKit is faster and more correct than any cross-platform capture crate
- AVAudioEngine gives you the PCM tap this design wants, directly
- **`SpeechAnalyzer` (macOS 26) gives you free, unlimited, fully on-device transcription** — which deletes §7 entirely: no API key, no rate limits, no 25MB cap, no internal screen recordings leaving the machine, no network. Groq becomes an optional accuracy upgrade rather than the backbone.

That last point is worth sitting with. Half the complexity in this spec — the queue, the retries, the rate-limit arithmetic, the local fallback in §7.8 — exists only because transcription is a metered network call. On a Mac-only build, most of it evaporates.

The spec below is written for Tauri. Say the word and the Swift variant is a smaller document, not a bigger one.

### 4.2 Portability discipline

Regardless of choice: keep `ChunkScheduler`, `TranscriptQueue`, `DocBuilder` and the `session.json` schema free of any framework imports. They are the actual product. The three capture services (hotkey, screen, audio) are the only platform-coupled code, and they are each under 200 lines.

---

## 5. Audio pipeline

### 5.1 Capture

`cpal` opens the default input device and gives you a callback with raw samples.

```rust
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

let host = cpal::default_host();
let device = host.default_input_device().expect("no input device");
let config = device.default_input_config()?;

let src_rate = config.sample_rate().0;   // often 44100 or 48000
let channels = config.channels();

let stream = device.build_input_stream(
    &config.into(),
    move |data: &[f32], _| {
        let mono = downmix_to_mono(data, channels);
        let pcm16 = resample_to_16k(&mono, src_rate);   // linear interp is fine for speech
        writer.append(&pcm16);                          // → session.raw
    },
    |err| log::error!("audio stream error: {err}"),
    None,
)?;
stream.play()?;
```

Two things `cpal` will not do for you that Chromium would have:

- **Resampling.** Most devices hand you 44.1kHz or 48kHz. You must resample to 16kHz yourself. Linear interpolation is genuinely adequate for speech at this ratio; reach for `rubato` only if you hear artefacts.
- **Downmixing.** Interleaved stereo needs averaging to mono.

Both are ~20 lines. This is the concrete cost of leaving Electron, and it is the largest single one.

16kHz mono is what Whisper uses internally, so there is nothing to gain from a higher rate and real bandwidth to lose.

**Do not enable echo cancellation or noise suppression** if the platform offers them. They are tuned for calls and they chew up narration recorded next to a fan.

### 5.2 Storage — byte offsets *are* timestamps

The audio callback appends `Int16` samples to a single `session.raw` file.

At **16kHz, mono, signed 16-bit little-endian**:

```
bytesPerSecond = 16000 × 2 = 32000
byteOffset(seconds) = round(seconds × 32000)
```

Slicing a chunk is then a `seek` + `read` at a computed offset. Exact, O(1), no seeking logic, no container parsing. This is the single design decision that makes the chunking trivial — and it is the reason raw PCM is worth its disk cost.

Disk cost: **1.92 MB/min**, ~115MB for a one-hour session. Delete `session.raw` after the document builds successfully, unless `keepRawAudio` is set (useful for re-transcribing with a better model without re-recording).

> **Rejected alternative:** encoding to Opus on the fly. ~10× smaller, but a compressed stream cannot be sliced at arbitrary offsets — each chunk would need its own container header, forcing a stop/restart of the encoder at every boundary, which drops frames at the seam and makes the tail/overlap logic impossible.

### 5.3 WAV encode

Whisper needs a container. Wrap the sliced PCM in a 44-byte WAV header — use `hound`, or write the header by hand in about 15 lines:

```rust
fn wav_header(pcm_len: u32) -> [u8; 44] {
    let mut h = [0u8; 44];
    h[0..4].copy_from_slice(b"RIFF");
    h[4..8].copy_from_slice(&(36 + pcm_len).to_le_bytes());
    h[8..12].copy_from_slice(b"WAVE");
    h[12..16].copy_from_slice(b"fmt ");
    h[16..20].copy_from_slice(&16u32.to_le_bytes());   // fmt chunk size
    h[20..22].copy_from_slice(&1u16.to_le_bytes());    // PCM
    h[22..24].copy_from_slice(&1u16.to_le_bytes());    // mono
    h[24..28].copy_from_slice(&16000u32.to_le_bytes()); // sample rate
    h[28..32].copy_from_slice(&32000u32.to_le_bytes()); // byte rate
    h[32..34].copy_from_slice(&2u16.to_le_bytes());    // block align
    h[34..36].copy_from_slice(&16u16.to_le_bytes());   // bits per sample
    h[36..40].copy_from_slice(b"data");
    h[40..44].copy_from_slice(&pcm_len.to_le_bytes());
    h
}
```

Groq accepts `wav` directly. **No ffmpeg dependency anywhere in this project.**

If you later want smaller uploads, FLAC roughly halves it losslessly — but at 2.8MB per 90-second chunk against a 25MB cap, there is nothing to solve.

### 5.4 VAD

Silero via the `voice_activity_detector` crate (ONNX through `ort`, ~2MB model, runs locally). Two jobs only:

1. **Empty-chunk detection.** If a chunk contains no speech, skip the API call entirely and emit the step with an empty narration. This is the single most valuable guard in the system — near-silent audio is precisely when Whisper hallucinates.
2. **Edge trimming.** Trim leading and trailing silence within a chunk. Cuts upload size and audio-seconds, and improves the first/last word.

Do **not** use VAD to strip interior silence. The savings are irrelevant against the rate limits and it damages the model's sense of pacing.

**Phase 3 refinement:** snap the computed boundary to the nearest VAD-detected silence within ±1000ms. Cuts in silence by construction, which makes the overlap and dedupe unnecessary. Worth doing, not worth blocking v1 on.

---

## 6. Screen capture

### 6.1 The call

`xcap` gives you monitors and full-resolution frames on both platforms.

```rust
use xcap::Monitor;

fn capture_at_cursor(path: &Path) -> anyhow::Result<()> {
    let (x, y) = cursor_position()?;                  // tauri or a small platform shim
    let monitor = Monitor::from_point(x, y)?;
    let image = monitor.capture_image()?;             // RgbaImage at native resolution
    image.save(path)?;                                // PNG via the `image` crate
    Ok(())
}
```

`xcap` returns the frame at native pixel resolution, so HiDPI is handled without a scale-factor dance. Confirm this on a Retina display in the Phase 0 spike anyway — it is the single assumption the whole image pipeline rests on.

`tauri-plugin-screenshots` wraps similar functionality if you would rather stay inside the plugin ecosystem; `xcap` gives more direct control and is what the plugin uses underneath.

### 6.2 Multi-monitor

Capture the monitor containing the cursor, as above. Do not capture all displays — it multiplies latency and produces documents nobody reads. Make "always capture monitor N" a config option for fixed setups.

### 6.3 Latency

Expect 50–200ms on a 5K display — better than an Electron equivalent, since there is no IPC hop and no Chromium in the path. Principle 4 says this should be imperceptible, and at these numbers it is.

**Latency would not matter even if it were worse**, and it is worth understanding why: with a global hotkey, nothing on screen moves between the keypress and the capture. There is no mouse traveling toward a button. The screen at `T_i + 200ms` is the screen at `T_i`.

This is the reason the earlier "capture a frame from 3 seconds ago" idea was dropped — it only existed to work around a browser's floating-button constraint, and a native hotkey deletes the problem.

Write the PNG encode and disk write on a worker thread, not in the hotkey handler. The handler should record `T_i`, hand off the raw frame, and return in microseconds.

### 6.4 Output images

**Write the screenshot at full native resolution and reference that from the markdown.** One image per step, `images/step-NN.png`, no downscaled variant.

The reason is legibility, and it is the only reason that matters here. You are usually capturing UI — a validation message, a dropdown with the wrong options, a stack trace in a console pane. Downscaling a 5K capture to 1600px is exactly what makes that small text unreadable, which destroys the thing you were trying to show. An unreadable screenshot is worse than no screenshot, because it looks like evidence.

Optional downscale belongs on the *export* path (§8.4), for the zip you attach to a Jira ticket where file size is someone else's problem too. Never on the default.

### 6.5 Click highlight (Phase 3)

The cursor position is already captured at marker time. Draw a 40px semi-transparent circle at that coordinate on the output PNG using the `imageproc` crate. Pure arithmetic, no ML, and it makes the documents dramatically more readable.

### 6.6 Window title (Phase 3)

`xcap::Window::all()` returns windows with titles and app names, and exposes `is_focused()` — so unlike the Electron path this needs no extra native dependency. Window title makes an excellent free step heading ("Settings — Google Chrome"). High value, low effort, but still after v1.

---

## 7. Groq Whisper integration

### 7.1 Endpoint

```
POST https://api.groq.com/openai/v1/audio/transcriptions
Authorization: Bearer $GROQ_API_KEY
Content-Type: multipart/form-data
```

OpenAI-compatible, so the official `openai` npm client works with `baseURL` overridden — or just use `FormData` + `fetch`, which is fewer dependencies for one endpoint.

### 7.2 Request

```rust
use reqwest::multipart::{Form, Part};

let mut form = Form::new()
    .part("file", Part::bytes(wav).file_name(format!("chunk-{i}.wav"))
        .mime_str("audio/wav")?)
    .text("model", "whisper-large-v3-turbo")
    .text("response_format", "verbose_json")
    .text("timestamp_granularities[]", "segment")
    .text("timestamp_granularities[]", "word")
    .text("language", "en")
    .text("temperature", "0");

if let Some(prev) = previous_text {
    form = form.text("prompt", tail_chars(prev, 200));
}

let res = client
    .post("https://api.groq.com/openai/v1/audio/transcriptions")
    .bearer_auth(&api_key)
    .multipart(form)
    .send()
    .await?;
```

Note `timestamp_granularities[]` is repeated, not comma-joined — the bracket suffix is part of the field name and the API expects two separate parts.

### 7.3 Parameters

| Parameter | Value | Notes |
|---|---|---|
| `model` | `whisper-large-v3-turbo` | Default. $0.04/hr, fast, multilingual |
| | `whisper-large-v3` | $0.111/hr. Use when narration code-switches (Hindi/English) — meaningfully better on mixed-language speech than turbo |
| | `distil-whisper-large-v3-en` | English only, cheapest, highest rate limits |
| `response_format` | `verbose_json` | Required for timestamps |
| `timestamp_granularities[]` | `word`, `segment` | Both. Segments carry the quality signals used in §7.5 |
| `language` | `en` | Setting it improves accuracy and speed. **Leave unset** if narration mixes languages — forcing `en` on Hinglish degrades output |
| `temperature` | `0` | Deterministic. Non-zero increases hallucination on quiet audio |
| `prompt` | last ~200 chars of previous chunk | Boundary continuity (§3.3) |
| `file` / `url` | one required | `url` avoids the 25MB cap entirely, but needs a public URL — not useful here |

**Supported formats:** flac, mp3, mp4, mpeg, mpga, m4a, ogg, wav, webm.

### 7.4 Response shape

```jsonc
{
  "task": "transcribe",
  "language": "english",
  "duration": 29.31,
  "text": "So I'm on the settings page and this dropdown …",
  "segments": [
    {
      "id": 0,
      "start": 0.0,
      "end": 3.24,
      "text": " So I'm on the settings page",
      "avg_logprob": -0.21,
      "no_speech_prob": 0.004,
      "compression_ratio": 1.41
    }
  ],
  "words": [
    { "word": "So", "start": 0.0, "end": 0.18 }
  ],
  "x_groq": { "id": "req_01j…" }
}
```

Timestamps are **chunk-relative**, which is exactly what you want — they are only ever used within a step.

### 7.5 Hallucination guard

Whisper reliably invents text over silence. VAD (§5.4) catches most of it; this catches the rest. Drop a segment when **any** of:

- `no_speech_prob > 0.6`
- `avg_logprob < -1.0`
- `compression_ratio > 2.4` (indicates repetition loops)
- normalised text matches the known-artefact list:
  `"thank you"`, `"thanks for watching"`, `"please subscribe"`, `"subtitles by …"`, `"amara.org"`, `"bye"`, `"you"`

If every segment in a chunk is dropped, the step gets an empty narration rather than a fabricated one. **An empty step is always better than a wrong one** — this document is going to be read as a factual record.

### 7.6 Rate limits (free tier)

| Limit | Value | What it means here |
|---|---|---|
| Requests/min | 20 | ~1 chunk every 3s sustained. Never hit in practice |
| Requests/day | 2,000 | ~200 ten-step sessions/day |
| Audio seconds/hour | 7,200 | 2 hours of audio per hour |
| Audio seconds/day | 28,800 | **8 hours of audio per day** |
| Max file size | 25MB free / 100MB dev | A 90s chunk is 2.8MB |

For 10-minute sessions this is roughly 48 sessions a day. The limits are not the constraint they appear to be — the 25MB per-request cap is the only one that ever bites, and §3.5 removes it.

Do not attempt to work around these with rotated keys across multiple accounts. It violates the terms, it gets the account killed, and as the table shows there is nothing to work around.

### 7.7 Queue and retries

- Concurrency **3**. Chunks close roughly every 30–90s, so the queue is almost always empty; concurrency exists for the burst when you mark several screens quickly.
- Retry on `429`, `5xx`, and network errors. Exponential backoff with full jitter, base 1000ms, max 5 attempts. Honour the `retry-after` header when present.
- **Never block recording on transcription.** The queue runs behind the session. If you stop recording with chunks in flight, the UI shows "transcribing 3 of 11" and the document writes when the queue drains.
- A chunk that fails all retries is recorded as `status: "failed"` in `session.json`. The document still builds, with `_[transcription failed — retry from session.json]_` in place of that step's narration.

### 7.8 Local fallback

Support `provider: "local"` in config, backed by `whisper.cpp` — either the `whisper-rs` bindings (in-process, no subprocess, fits the small-and-quiet principle better) or shelling out to `whisper-cli --model ggml-base.en.bin --output-json`. Same input, same output shape after a thin adapter.

Worth having for three reasons, in order of how likely they are to matter: recordings of internal Ema tooling going to a third-party API is a real question at work; it works on a plane; and it has no caps at all. Latency is irrelevant here — you transcribe a 90-second chunk in the background while still recording — which means Groq's actual advantage (speed) is the one thing this workload does not need.

Define the provider trait in Phase 1 even though only Groq implements it. It is three methods, and it is what keeps §7's queue-and-retry machinery from leaking into the rest of the app:

```rust
trait Transcriber {
    async fn transcribe(&self, wav: Vec<u8>, prompt: Option<&str>)
        -> Result<Transcript, TranscribeError>;
}
```

On a Mac-only Swift build this trait is where `SpeechAnalyzer` would slot in, and it would become the default rather than the fallback (§4.1).

---

## 8. Output

### 8.1 Folder layout

```
~/ScreenDoc/
  2026-09-15_14-32-11_dropdown-bug/
    doc.md
    session.json
    images/
      step-01.png         full native resolution — referenced by doc.md
      step-02.png
      …
    audio/
      session.raw         deleted unless keepRawAudio
```

### 8.2 `session.json` — the source of truth

The markdown is a *render*, not the record. Keeping `session.json` means you can change the document template, re-run a failed chunk, or re-transcribe with a better model, all without recording again.

```jsonc
{
  "id": "2026-09-15_14-32-11",
  "title": "dropdown bug",
  "startedAt": "2026-09-15T14:32:11+05:30",
  "durationMs": 494000,
  "config": {
    "tailMs": 5000,
    "overlapMs": 1000,
    "provider": "groq",
    "model": "whisper-large-v3-turbo"
  },
  "steps": [
    {
      "index": 1,
      "markerAtMs": 24310,
      "screenshot": "images/step-01.png",
      "display": { "id": 1, "width": 2560, "height": 1440, "scaleFactor": 2 },
      "cursor": { "x": 840, "y": 512 },
      "windowTitle": "Settings — Google Chrome",
      "audio": {
        "startMs": 0, "endMs": 29310,
        "byteStart": 0, "byteEnd": 937920,
        "hasSpeech": true
      },
      "transcript": {
        "status": "ok",
        "text": "So I'm on the settings page and this dropdown …",
        "words": [{ "word": "So", "start": 0.0, "end": 0.18 }],
        "droppedSegments": 0,
        "model": "whisper-large-v3-turbo",
        "requestId": "req_01j…"
      }
    }
  ],
  "closingNotes": { "status": "ok", "text": "…" }
}
```

### 8.3 `doc.md` template

```markdown
---
title: Dropdown bug
recorded: 2026-09-15T14:32:11+05:30
duration: 8m14s
steps: 6
source: ScreenDoc
---

# Dropdown bug

<!-- optional free-text context typed in the tray UI before or after recording -->

## Step 1

![Step 1](images/step-01.png)

> So I'm on the settings page and this dropdown here is supposed to show all
> five regions but it's only showing two.

<sub>`00:00–00:29` · Settings — Google Chrome</sub>

---

## Step 2

![Step 2](images/step-02.png)

> And if I open the network tab you can see the response actually has all five,
> so it's not the API.

<sub>`00:29–01:02` · DevTools — Google Chrome</sub>

---

## Closing notes

> So yeah, I think it's a filtering thing on the client side. Have a look at
> whatever renders that list.
```

**Format decisions, and why:**

- **Image above narration.** The reader (human or model) orients on the picture, then reads the claim about it.
- **Narration as a blockquote.** Visually marks it as *spoken by a person* rather than as instruction to a model. This matters when the document is a prompt — the agent should treat it as evidence, not as commands.
- **Relative image paths, not base64.** A 10-step base64 document is unreadable in any editor and inflates context cost. Ship the folder; every agent tool that reads local files handles it. Provide "Export as single self-contained .md" as an explicit option for pasting into a chat box.
- **YAML frontmatter.** Cheap, and makes the corpus queryable once you have fifty of these.
- **Timestamps in `<sub>`.** Present for traceability, visually out of the way.

### 8.4 Export options

| Export | File | Use |
|---|---|---|
| Folder (default) | `doc.md` + `images/` | The human-readable record — Jira, GitHub, a teammate |
| Agent prompt | `PROMPT.md` + `images/` | Point Claude Code or Cursor at the folder (§8.5) |
| Self-contained | one `.md`, base64 images | Paste into a chat box where relative paths mean nothing |
| Archive | `.zip` | Attach to a ticket or a Slack thread |

All four render from the same `session.json`. Generate on demand, not at record time.

### 8.5 Will Claude Code or Cursor actually read this?

Mostly yes, with one thing you have to design around.

**The thing:** when an agent reads `doc.md`, it gets the *text* of the file. `![Step 1](images/step-01.png)` arrives as that literal string, not as a picture. Claude Code's Read tool does render PNGs visually — but as a separate, deliberate call per image. Nothing loads the screenshots automatically just because markdown references them.

So the document has to do two things:

**1. Tell the agent to open them.** `PROMPT.md` starts with an instruction block:

```markdown
> **Reading this:** this is a narrated screen recording. There are 6 steps.
> Each step has a screenshot in `images/` and a transcript of what I said
> while looking at it. **Open every screenshot before answering** — read
> `images/step-01.png` through `images/step-06.png` in order. The steps are
> sequential; step 3 follows from step 2.
```

Explicit, numbered, with the count stated. Without it you get an answer based on your narration alone, which is often plausible and wrong.

**2. Stand alone as text.** The narration has to carry the argument by itself, because sometimes the images won't be loaded — Cursor in particular is inconsistent at reading images from file paths (pasted images work reliably; path-based reads are reported as unreliable with custom API models). Treat images as strong supporting evidence, not as the only carrier of meaning.

**Sequence is not a problem.** Step order is explicit in the headings, in the filenames (`step-01`, `step-02`) and in the timestamps. Both tools follow it without difficulty. This is the one thing you might have expected to break, and it doesn't — because the marker keypress already made the order explicit, rather than leaving it to be inferred.

**Practical shape that works today:**

```
you: read PROMPT.md in this folder and fix what I described
```

That is it. The instruction block inside the file handles the rest.

---

## 9. Edge cases

| # | Case | Handling |
|---|---|---|
| 1 | Marker pressed before any speech | VAD reports no speech → step emitted with empty narration, no API call |
| 2 | Two markers within the tail window | Chunk closes early at `T_{i+1}`; step `i+1` gets little or no "before" narration. Inherent — document it in the UI, do not try to be clever |
| 3 | Marker pressed with no session running | Ignore, flash the tray icon. Do **not** auto-start — you will get sessions with no audio |
| 4 | First chunk | `start = 0`. Contains everything said before the first marker |
| 5 | Last chunk | `end = min(T_k + TAIL, T_stop)`; remainder → Closing notes (§3.4) |
| 6 | Zero markers in a session | Emit a document with no steps and the full narration as Closing notes. Warn in the UI |
| 7 | Mic permission denied mid-session | Keep capturing screenshots, mark all transcripts `status: "no_audio"`, still build the document |
| 8 | Disk fills during recording | Stop the session cleanly, keep what exists, build the document from completed steps |
| 9 | Display disconnected between markers | `getDisplayNearestPoint` handles it; record the display id per step so the change is visible |
| 10 | Screen locks / screensaver | Screenshot would be of the lock screen. Auto-pause on the platform lock notification (`com.apple.screenIsLocked` via `NSDistributedNotificationCenter` on macOS; `WTSSESSION_CHANGE` on Windows) |
| 11 | Machine sleeps mid-session | On sleep, close the current chunk and pause. On wake, start a new chunk. Do not span the gap — a chunk containing an eight-hour discontinuity produces nonsense |
| 12 | Session longer than an hour | No hard limit, but warn at 60min. `session.raw` is ~115MB/hr |
| 13 | Groq key missing or invalid | Record normally, queue everything, surface one clear error. Never lose a recording to a config problem |
| 14 | App quit during recording | Flush `session.raw`, write `session.json` with `status: "interrupted"`, recover on next launch |

---

## 10. Permissions and first run

### macOS

| Permission | Needed for | Notes |
|---|---|---|
| Screen Recording | `xcap` capture | **Requires app restart after granting.** This is TCC behaviour, not a bug. Probe with `CGPreflightScreenCaptureAccess()`, request with `CGRequestScreenCaptureAccess()`, and if newly granted show a dialog that offers to relaunch |
| Microphone | `cpal` input stream | Standard prompt. `NSMicrophoneUsageDescription` required in Info.plist |
| Accessibility | — | **Believed not required.** `tauri-plugin-global-shortcut` registers standard modifier+key accelerators through Carbon `RegisterEventHotKey`, which does not need Accessibility. Media keys (F7/F8/F9 on some layouts) go through a different path and do. **Verify in the Phase 0 spike** — if a chosen default hotkey turns out to need it, change the default rather than asking for the permission. An app that demands Accessibility fails principle 5's spirit |

Info.plist additions: `NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription` (macOS 14.2+).

Also set `LSUIElement = true` so the app has no dock icon and lives only in the menu bar (principle 1). In Tauri this is `tauri.conf.json` → `bundle.macOS.dockVisibility: false`, or the raw Info.plist key.

### Windows

No permission prompts for screen capture. Microphone access is governed by Settings → Privacy → Microphone; if blocked, the `cpal` stream fails to build and you surface a link to that page. Global hotkeys register without ceremony.

Set `skipTaskbar` on the popover window so it behaves like a tray utility rather than an app.

### First-run flow

1. Welcome → what the tool does, in three lines
2. Request microphone
3. Request screen recording (macOS: explain the restart, offer to do it)
4. Ask for the Groq API key — link to `console.groq.com/keys`, **Validate** before accepting it, and a "skip for now" that leaves the app usable (screenshots still captured, transcription queued until a key exists)
5. Show the two hotkeys and let them be changed right there, with the Test button available

Steps 4 and 5 are the settings window's Transcription and Hotkeys sections, reused rather than rebuilt. First run is the settings window with a Next button.

---

## 11. Hotkeys and configuration

### Defaults

| Action | macOS | Windows |
|---|---|---|
| Start / stop session | `⌘⇧R` | `Ctrl+Shift+R` |
| Mark screen | `⌘⇧S` | `Ctrl+Shift+S` |
| Cancel and discard | `⌘⇧Esc` | `Ctrl+Shift+Esc` |

The marker hotkey is pressed dozens of times per session, so it must be comfortable one-handed. Offer `F9` as a preset alternative — single key, far faster, but higher collision risk with other apps.

These are defaults, not decisions. **Both hotkeys are reconfigurable by the user and this is a v1 requirement, not a Phase 3 nicety** (§1, line 3).

Registration fails when a combination is already taken by another app. Surface that immediately in the settings window rather than failing silently at record time — a marker hotkey that quietly does nothing is the worst failure this tool can have, because you don't find out until the document comes out empty an hour later.

### The settings window

One window, three sections, opened from the tray menu. Native-feeling, small, no tabs if it fits without them.

**Hotkeys**

A hotkey recorder widget per action — click the field, press the combination, it captures and displays it. Not a text box where you type `CommandOrControl+Shift+R`; nobody should have to know that syntax.

Each field validates on capture and shows one of three states:

| State | Display |
|---|---|
| Free | ✓ green, saved immediately |
| Taken by another app | ✗ "This shortcut is in use by another app" — refuse to save |
| Needs Accessibility (media keys) | ⚠ "This key needs Accessibility permission. Pick another?" |

Include a **Test** button next to the marker hotkey that fires a capture and shows the resulting thumbnail. This is the one thing that proves the whole chain works before you rely on it in a real session.

**Transcription**

- API key field — masked, with a **Validate** button that makes one cheap real request and reports back: ✓ "Connected — whisper-large-v3-turbo", or the actual error (bad key / no network / rate limited). Never store a key without validating it first.
- Link to `console.groq.com/keys` next to the field, since that is where the user has to go.
- Model dropdown: turbo (default) / large-v3 (better on mixed Hindi-English) / local Whisper.
- Language: Auto / English / other. Note in the UI that Auto is the right choice for code-switched narration.

The key is written to the OS keychain, never to the config file, and never logged.

**Recording**

- Output folder picker (default `~/ScreenDoc`)
- Tail seconds slider, 0–15s, default 5 — label it in plain words: *"Keep recording for N seconds after each capture, so explanations that come after the click stay with the right screenshot."*
- Feedback toggles: sound / tray flash / border flash
- Keep raw audio after building the document (off)

Everything saves on change. No OK/Apply buttons.

### What is not in settings

Overlap, VAD thresholds, concurrency, retry policy, hallucination-guard cut-offs, image width. These live in the config file for when you need to change one, and they stay out of the window. Principle 6 — the settings window is for the three things in §1 plus the handful above, and it should stay short enough to read in one glance.

### Feedback on marker press

Non-negotiable: you need to know it registered without looking away from your work (principle 2 — the UI is not on screen). Ship all three, each toggleable:

- A short click sound (~50ms) — **default on**, and it does not pollute the recording because system audio is not captured, only the microphone
- Tray icon flash, plus a step counter in the tray title
- A 200ms border flash around the captured monitor, drawn in a click-through always-on-top transparent window

### `~/.screendoc/config.json`

```jsonc
{
  "hotkeys": {
    "toggleSession": "CommandOrControl+Shift+R",
    "marker": "CommandOrControl+Shift+S",
    "cancel": "CommandOrControl+Shift+Escape"
  },
  "chunking": { "tailMs": 5000, "overlapMs": 1000, "snapToSilence": false },
  "transcription": {
    "provider": "groq",
    "model": "whisper-large-v3-turbo",
    "language": "en",
    "concurrency": 3
  },
  "capture": { "displayMode": "cursor", "clickHighlight": false },
  "output": { "directory": "~/ScreenDoc", "keepRawAudio": false },
  "feedback": { "sound": true, "trayFlash": true, "borderFlash": true }
}
```

API key in the OS keychain via the `keyring` crate (Keychain on macOS, Credential Manager on Windows) — never in the config file.

---

## 12. Build phases

### Phase 0 — Spike (half a day)

No audio at all. Prove the capture loop and kill the platform risk.

- Tauri app, tray icon only (no dock icon, no window), two global hotkeys
- Marker → full-res screenshot of the cursor's monitor → PNG on disk
- Stop → `doc.md` with images and no narration

**Exit criteria, all four:**

1. Works on macOS and Windows
2. Screenshots are genuinely full resolution on a HiDPI display
3. The marker hotkey works *without* Accessibility permission
4. Measured hotkey-to-frame-captured latency under 200ms

Everything downstream assumes these. Find out in half a day rather than in week three.

### Phase 1 — v1 (the real thing)

- `cpal` capture → downmix → resample → `session.raw`
- `ChunkScheduler` with tail and overlap
- WAV slicing by byte offset
- `Transcriber` trait; Groq implementation with queue and retries
- Dedupe at seams, `prompt` continuity
- `session.json` + `doc.md`
- Tray popover: recording state, step count, queue progress
- **Settings window: hotkey recorders for both keys, API key field with Validate, output folder, tail slider** — this is §1 line 3 and it ships in v1, not later

**Exit criteria:** record a real 10-minute debugging session end to end and have the document be something you would actually send to someone.

### Phase 2 — Make it trustworthy

- Silero VAD: empty-chunk skip and edge trimming
- Hallucination guard (§7.5)
- Session browser; rebuild `doc.md` from `session.json`; retry failed chunks
- Sleep / lock handling
- Export formats
- First-run permission flow

### Phase 3 — Make it good

- Click highlight on screenshots
- Window titles via `xcap::Window`, used as step headings
- Boundary snapping to silence
- Local `whisper.cpp` provider
- Editable steps: reorder, delete, re-record narration for one step
- Optional title generation from the transcript

---

## 13. Open questions

1. **Title.** Auto-generate from the first chunk, prompt for one at stop, or just use the timestamp? Leaning: prompt at stop with a suggestion prefilled from the first sentence.
2. **The "what I need" line.** Resolved in part by §8.4 — `doc.md` stays a neutral record and `PROMPT.md` carries the agent framing. Still open: should the tray prompt for a one-line "what I want done about this" at stop, while it is still in your head, or leave it for you to type into the file later? Leaning toward asking at stop — it is the single highest-value sentence in the document and the one most likely to be forgotten.
3. **Redaction.** Screenshots of internal tools will contain customer names, emails, tokens in URLs. Blur-a-region-before-export is real work but this is the one feature that decides whether these documents can be shared outside the team. Worth scoping properly before Phase 3.
4. **Video.** Everything here produces stills. Some steps genuinely need motion (an animation glitch, a race condition). Recording an optional 3-second clip around a marker is a contained addition — worth doing only if it comes up in real use.
5. **Windows, honestly.** The whole stack choice in §4.1 turns on this. If after a month of use the Windows build has been run zero times, the Swift rewrite gets a faster, smaller, more native app *and* free unlimited on-device transcription. Worth an explicit decision at the end of Phase 1 rather than drift.
6. **Distribution.** Maccy is on Homebrew and notarised. If this is only ever yours, skip signing entirely. If it goes to the team, macOS notarisation and a Windows code-signing certificate are the real cost of "just send me the app" — budget for it before promising it.

---

## 14. Appendix — Groq quick reference

```
Endpoint   POST https://api.groq.com/openai/v1/audio/transcriptions
Auth       Authorization: Bearer $GROQ_API_KEY
Body       multipart/form-data

Models     whisper-large-v3-turbo        $0.04/hr   multilingual, fast
           whisper-large-v3              $0.111/hr  multilingual, best accuracy
           distil-whisper-large-v3-en    cheapest   English only

Formats    flac mp3 mp4 mpeg mpga m4a ogg wav webm
Max size   25MB (free) / 100MB (dev)

Free tier  20 RPM · 2,000 RPD · 7,200 audio-sec/hr · 28,800 audio-sec/day
```

**Sources**

- [Groq — Speech to Text](https://console.groq.com/docs/speech-to-text)
- [Groq — API reference](https://console.groq.com/docs/api-reference)
- [Groq — Rate limits](https://console.groq.com/docs/rate-limits)
- [Tauri v2 — Global Shortcut plugin](https://v2.tauri.app/plugin/global-shortcut/)
- [Building a macOS menu bar app with Tauri v2](https://dev.to/hiyoyok/complete-guide-to-building-a-macos-menu-bar-app-with-tauri-v2-aji)
- [`xcap` — cross-platform screen capture](https://crates.io/crates/xcap)
- [`cpal` — cross-platform audio I/O](https://crates.io/crates/cpal)
- [`tauri-plugin-screenshots`](https://crates.io/crates/tauri-plugin-screenshots)
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp)
- [Maccy](https://maccy.app/) · [source](https://github.com/p0deje/Maccy) — the behavioural reference for §1a
- [Apple — SpeechAnalyzer (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/277/) — relevant only if the Mac-only path in §4.1 is taken
