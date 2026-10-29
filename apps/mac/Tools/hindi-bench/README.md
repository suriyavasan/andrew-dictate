# hindi-bench

a developer tool, not part of the app. it chooses, on measured numbers, the
on-device engine for real-time Hindi (and Hinglish) captions, and shows what a
language lock fixes in whisper. the results and the recommendation are in
[REPORT.md](REPORT.md). this is the phase 1 of `apps/mac/PLAN-live-translation.md`.

engines (candidates A, B, C, C' of the plan):

- **a** Apple `DictationTranscriber`, locale `hi-IN`, volatile results, on a
  `SpeechAnalyzer`. (`SpeechTranscriber` has no Hindi; `probe` shows it.)
- **b** NVIDIA Nemotron 3.5 ASR streaming 0.6B, the CoreML build FluidAudio 0.18
  downloads (`FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML`,
  `multilingual/<chunk>ms`), language `hi-IN` by prompt id, or `auto`.
- **c** WhisperKit large-v3 on VAD stretches, decoded as the app does (language
  nil, detection on, temperature 0).
- **c'** the same with the language forced to `hi` (`--mode hi`), or detection
  limited to `{hi, en}` (`--mode hien`: the argmax of whisper's language
  probabilities over those two, then decoded in it).
- Apple Translation, Hindi to English (`translate`).

models come from the folders the app keeps (`~/Library/Application Support/FluidAudio/Models`).
whisper large-v3 is read from there and never downloaded; if it is missing the
tool says so. Nemotron (640 MB per chunk-size bundle) and the Silero VAD
download on first use. the first Nemotron load also compiles for the neural
engine and takes minutes; later loads take seconds. the hi-IN dictation asset
is installed through `AssetInventory` on the first `--engine apple` run.

## build

```
cd apps/mac/Tools/hindi-bench
swift build -c release
```

FluidAudio is pinned to 0.18.0 here (the Nemotron 3.5 multilingual streaming
manager first ships in 0.18.0); the app stays on 0.15.5, this is a separate
package. WhisperKit is the app's 1.1.0. always time with the release build, and
do not build while a timed run is going.

## 0. audio

the audio is scratch and never committed. keep it in `/tmp/hindi-bench`.

```
mkdir -p /tmp/hindi-bench/fleurs /tmp/hindi-bench/real
cd /tmp/hindi-bench/fleurs
curl -sL -o hi.parquet https://huggingface.co/api/datasets/google/fleurs/parquet/hi_in/test/0.parquet
curl -sL -o en.parquet https://huggingface.co/api/datasets/google/fleurs/parquet/en_us/test/0.parquet
cd apps/mac/Tools/hindi-bench
uv run --with pyarrow scripts/prep_fleurs.py --hi /tmp/hindi-bench/fleurs/hi.parquet \
    --en /tmp/hindi-bench/fleurs/en.parquet --out /tmp/hindi-bench/fleurs --n 150
```

FLEURS `hi_in` test, 150 sentences (one recording per sentence id, seeded
shuffle), as 16 kHz mono float wavs plus `refs.json`; the same sentence id in
`en_us` is the English reference.

real conversational Hindi and Hinglish, no references (`scripts/fetch-real.sh`
lists the five clips used and downloads them; `ffmpeg` is not needed, macOS
`afconvert` converts). `hindi-bench cut` then cuts each into VAD stretches, the
way the app cuts them (Silero, 0.5 s pause, 25 s cap).

## 1. runs

```
scripts/run-all.sh                     # every run below, one at a time, into /tmp/hindi-bench/runs (about 2 hours)
.build/release/hindi-bench probe       # what this mac has: dictation locales, translation pack state
.build/release/hindi-bench run --engine nemo --chunk-ms 2240 --set fleurs --n 60 --out nemo.json
.build/release/hindi-bench run --engine apple --set real --seconds 120 --out apple-real.json
.build/release/hindi-bench run --engine whisper --mode hien --set fleurs --n 60 --out w.json
.build/release/hindi-bench score nemo.json apple-real.json w.json [--limit 60]
```

**the clocks.** audio always goes in as 100 ms, 16 kHz mono chunks, like
`MeetingAudioChunk`, with one second of silence after the speech so a recogniser
can settle.

- apple: **real time**. each chunk is handed over at its wall-clock moment, the
  recogniser is a system service and its own timing is what is measured.
- nemotron: **simulated clock**. a chunk arrives at its real-time moment, the
  time the call takes is measured, and a call that starts late (the engine was
  still busy) delays what follows. the same numbers as real pacing, in a
  fraction of the time, as long as nothing else competes.
- whisper: **simulated clock**, as `meeting-bench simulate`: a stretch is available when
  the VAD knows it is over (speech end + 0.5 s pause + one 256 ms VAD step), one decoder per clip,
  in order, and the decode time is measured.

**the metrics** (`score`).

- WER and CER against the FLEURS Hindi reference, after normalising both: NFC,
  lowercase, nukta dropped, candrabindu folded to anusvara, joiners dropped,
  Devanagari digits to ASCII, punctuation and symbols (the danda too) removed.
- latency per word, against an estimate of when the word was spoken. FLEURS has
  no word timings, so a word's end is placed inside the unit's speech span (found
  from the audio energy) in proportion to its characters. that is good to a few
  tenths of a second and the same for every engine, so it ranks them, but it is
  not a force alignment. *first-appears* is the first caption that has the word;
  *settled* is after the last caption in which that word was missing or different.
  also printed: the first caption after speech starts, and the final text after the speech ends.
- real-time factor (compute seconds per audio second; for apple it is the paced
  wall time, so only about 1 and not a measure of its cost), peak resident memory
  of this process (apple's engine runs in a system service, not counted), model size on disk.
- language: whisper's detected language per unit, flips between consecutive
  stretches of a clip, hi<->ur flips, lines with Arabic or Urdu script
  (U+0600-06FF, 0750-077F, FB50-FDFF, FE70-FEFF), lines with Devanagari, and
  how many output words contain Latin letters (English kept as English).

extras from the run files (flicker, side-by-side samples, per-clip language table,
whisper's task=translate score):

```
python3 scripts/analyze.py flicker  /tmp/hindi-bench/runs/nemo1120-fleurs150.json --limit 60
python3 scripts/analyze.py samples  a.json b.json --n 10
python3 scripts/analyze.py clips    /tmp/hindi-bench/runs/whisper-auto-real.json
python3 scripts/analyze.py translate-f1 /tmp/hindi-bench/runs/whisper-auto-fleurs.json
```

## 2. translation

```
.build/release/hindi-bench install-translation     # once: opens a window, click Download if macOS asks
.build/release/hindi-bench translate --from fleurs --n 150 --out /tmp/hindi-bench/runs/translate-ref.json
.build/release/hindi-bench translate --from /tmp/hindi-bench/runs/nemo2240-fleurs150.json --n 60 --out /tmp/hindi-bench/runs/translate-nemo.json
```

`TranslationSession(installedSource: hi, target: en)`. a CLI cannot download the
pack itself: macOS asks through a view with a consent sheet (`install-translation`
opens one) or it can be added in System Settings > General > Language & Region >
Translation Languages. each sentence is translated whole and its first six words
alone (what re-translating a growing partial would cost), with the latency of
each, and a unigram F1 against the English FLEURS sentence.

## what the numbers do not say

- FLEURS is read speech, one speaker, clean. the real clips are YouTube
  recordings with no reference, so they give latency, language stability and
  things to read, not accuracy.
- the machine is shared, and macOS Low Power Mode throttles it when it is on (it was
  on for the runs in REPORT.md; `pmset -g | grep lowpowermode`). other work and the
  running app move every timed number; whisper's decode times swing most. turn Low
  Power Mode off and run `scripts/run-all.sh` again for numbers that can stand as
  absolutes.
- the latency of a word is an estimate (above).
