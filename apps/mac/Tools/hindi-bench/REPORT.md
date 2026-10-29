# hindi-bench report: the live Hindi engine

phase 1 of `apps/mac/PLAN-live-translation.md`, run 2026-10-29. how to reproduce is in
[README.md](README.md). everything here is read off the run files in `/tmp/hindi-bench/runs`
(not committed). "not measured" is said where it is true.

## recommendation

**use Nemotron 3.5 ASR streaming 0.6B (CoreML, FluidAudio >= 0.18) with the Hindi prompt, at
the 1.12 s chunk size, as the live engine.** on 60 FLEURS Hindi sentences it has a WER of 12.6 %
(Apple's dictation: 30.1 %, whisper large-v3 as the app runs it: 46.2 %), words appear a median
0.6 s after they are spoken (p90 1.4 s), 5 to 11 % of shown words are later changed (Apple: 37 to
52 %), it wrote nothing in Arabic script, it keeps Hinglish readable, and it uses a hundredth of
whisper's compute (real-time factor 0.03). nothing else tested gets near it on Hindi.

keep whisper large-v3 as the accurate saved transcript, but never with free language detection:
limit it to {hi, en} (Hindi and English) or force `hi`. that alone took whisper from 9 Urdu-script
lines in 60 to none and from 46 % to 31.5 % WER. it is still the weaker Hindi model here and slow
on this mac (below).

Apple's `DictationTranscriber` is the one to keep in mind as a zero-download draft (words after 0.3 s,
no model to fetch, 30 % WER, a third to a half of the words it shows get rewritten), not as the
captions.

## what was run

| | |
|---|---|
| machine | MacBook Pro, Apple M2 Pro, 16 GB, macOS 26.5. **Low Power Mode was on** and the machine was shared with the running Andrew Dictate app and other work (load average 2 to 4). absolute timings, whisper's most, are pessimistic. |
| A | Apple `DictationTranscriber`, `hi-IN`, volatile results, audio time ranges, on a `SpeechAnalyzer`; real-time wall clock. |
| B | Nemotron 3.5 ASR streaming 0.6B, FluidAudio 0.18.0, `multilingual/` bundle, prompt id `hi-IN` (6) at 1120 ms and 2240 ms chunks, and `auto` (101) at 2240 ms; simulated clock. |
| C | WhisperKit 1.1.0, large-v3 from the app's folder; VAD stretches, language nil, detection on, temperature 0 (the app's own settings, default fallback on). simulated clock. |
| C' | the same with `language = hi`, and with detection limited to {hi, en} (argmax of whisper's language probabilities over those two, then decoded in it). |
| FLEURS | `hi_in` test, 150 sentences (60 for the cross-engine table; the first 60 of the same shuffled list). 29 min, read speech, references in Devanagari and the parallel `en_us` sentence. |
| real clips | five YouTube clips, the first 120 s of each cut by Silero VAD into 58 stretches (8.0 min of speech). no references. `hindi-meeting` (7 points for meetings, Hindi with English terms), `hindi-monologue` (Hindi), `hinglish-shamani` (a podcast clip, heavy Hindi/English mixing, the real Hinglish case), `hinglish-casual` (a noisy vlog: 23 stretches, 13 of them empty in Nemotron: laughter, music, sub-second sounds), `hinglish-zudio` (**turned out to be spoken in English** with an Indian accent, not Hinglish; useful as the "English speech under a Hindi lock" case). |

all engines get 100 ms 16 kHz chunks and one second of silence after the speech. the clocks
and the word-latency estimate are described in the README; the short version is that a word's
spoken time is estimated in proportion to its characters inside the unit's speech span (no
word timings exist for FLEURS), so latencies rank the engines but are good to a few tenths of a second.

## results, FLEURS hi_in, the same 60 sentences (11.8 min)

| engine | WER | CER | word shown after spoken, median / p90 | word settled, median / p90 | first caption after speech starts | final text after speech ends | shown words later changed | real-time factor | Arabic/Urdu-script lines | model on disk | process memory |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **A** Apple dictation hi-IN | 30.1 % | 23.7 % | 0.34 / 1.13 s | 0.54 / 1.96 s | 0.84 s | 1.88 s | 52 % | paced (about 1.1; not a cost) | 0 | system asset, size not read | 29 MB (service not counted) |
| **B** Nemotron hi-IN 1120 ms | **12.6 %** | **8.8 %** | **0.58 / 1.37 s** | 0.69 / 1.47 s | 1.36 s | 1.82 s | 10.7 % | 0.030 | 0 | 641 MB | 100 to 260 MB (641 MB peak while first compiling) |
| B Nemotron hi-IN 2240 ms | 12.8 % | 8.8 % | 1.14 / 2.19 s | 1.23 / 2.33 s | 2.01 s | 1.83 s | 5.4 % | 0.023 | 0 | 640 MB | 100 to 260 MB |
| B Nemotron auto 2240 ms | 12.8 % | 9.2 % | 1.13 / 2.19 s | 1.25 / 2.32 s | 2.01 s | 1.84 s | 5.3 % | 0.024 | **1** (30 chars of Arabic in one line) | 640 MB | |
| **C** whisper large-v3, as the app | 46.2 % | 51.8 % | 16.8 / 76.1 s | 16.8 / 76.1 s | 19.3 s | 9.7 s | n/a (no partials) | 1.65 | **9 of 60** | 2.9 GB | 290 to 610 MB |
| C' whisper, forced `hi` | 32.6 % | 23.4 % | 16.4 / 86.0 s | same | 19.4 s | 9.8 s | n/a | 1.80 | 2 (2 stray characters) | 2.9 GB | 331 MB |
| C' whisper, {hi, en} | 31.5 % | 22.5 % | 17.2 / 90.7 s | same | 20.2 s | 10.6 s | n/a | 1.99 | 1 (1 stray character) | 2.9 GB | 324 MB |

Nemotron over all 150 sentences: 1120 ms WER 11.9 % / CER 8.2 %, 2240 ms 12.1 % / 8.3 %.

notes on reading it:

- **whisper's latency here is not an engine number.** a FLEURS sentence is one stretch, available 0.64 s after its speech
  ends, then decoded. the 16 s median is the decode itself: 1.65 to 2 s per second of audio on this mac in Low
  Power Mode, with temperature fallback re-decoding a stretch up to six times (a 17 s clip took 60 s;
  with fallback off, 6 clips took 5 to 16 s each, about real time). the structural floor for a stretch engine
  is still the stretch itself plus 0.64 s: with the app's stretches of up to 25 s, a word waits on average
  half the stretch before decoding starts. that is why this engine cannot be the live one even on a fast mac.
- **Apple's numbers are fast and wrong.** words appear after about 0.3 s, but half of them change before
  they settle, it drops words (a 15-word sentence, FLEURS 1993, came back as 9), and WER is 2.4 times Nemotron's.
- **Nemotron writes numbers as words** ("अठारह सौ" for 1800) which costs a little WER against the
  digit references; no inverse text normalisation was applied.
- the chunk size is a floor: the 2240 ms bundle cannot show anything before 2.24 s of audio, the
  1120 ms bundle before 1.12 s. 1120 ms costs nothing in accuracy (12.6 vs 12.8 %) and doubles the rewrites a
  little (10.7 vs 5.4 % of words). the 560 ms bundle exists and was not run; its README says it is off the trained tiling.

## results, real clips (58 stretches, 8.0 min of speech, no references)

| engine | words written | word shown after spoken, median / p90 | first caption after speech starts | words with Latin letters | Arabic/Urdu-script lines | language flips between stretches | real-time factor |
|---|---|---|---|---|---|---|---|
| A Apple dictation | 1150 | 0.24 / 1.42 s | 0.61 s | 5 (English comes out in Devanagari) | 0 | none possible (fixed locale) | paced |
| B Nemotron hi-IN 1120 ms | 1512 | 0.55 / 1.44 s | 1.13 s | 0 (English in Devanagari) | 0 | none possible | 0.035 |
| B Nemotron hi-IN 2240 ms | 1510 | 1.14 / 2.26 s | 2.25 s | 0 | 0 | none possible | 0.027 |
| B Nemotron auto 2240 ms | 1502 | 1.16 / 2.34 s | 2.25 s | 282 (English kept as English; tags: hi 11, en 3) | 0 | 0 | 0.028 |
| C whisper, as the app | 1231 | 72 / 138 s (the queue never catches up) | 95 s | 511 | **5 lines (all in `hindi-monologue`)** | **21 of 53, of which hi<->ur 6** | 1.94 |
| C' whisper, forced `hi` | 1060 | 107 / 214 s | 106 s | 162 | 2 (2 stray characters) | 12 of 53 (labels on empty or noisy vlog stretches), hi<->ur 0 | 2.59 |
| C' whisper, {hi, en} | 1241 | 84 / 179 s | 97 s | 491 | **0** | 12 of 53 (all in the noisy vlog), hi<->ur 0 | 2.12 |

per clip, whisper as the app runs it: `hindi-monologue` 19 stretches, 16 `hi` and 3 `ur`, **6 hi<->ur flips and 5 lines
in Arabic script**; `hindi-meeting` and `hinglish-shamani` 0 flips; `hinglish-zudio` all `en` (correct: it is English);
`hinglish-casual` 15 flips between `hi`, `en`, `hu`, `tr`, `ru`, `te` on laughter and noise (mostly empty text, a few garbage lines). with the
{hi, en} limit the monologue is `hi` for all 19 stretches and has no Arabic characters at all.

about whisper's real-clip latency: the decoder is slower than the audio here (RTF 1.9 to 2.6, same caveats as above), so the queue
grows over the 8 minutes and the figures are a measure of "does not keep up on this mac in Low Power Mode", not of a healthy run. rerun with Low Power Mode off before quoting them.

## what the language lock fixed (C vs C')

| 60 FLEURS sentences | C: detection free | C': forced `hi` | C': {hi, en} |
|---|---|---|---|
| detected language | hi 48, **ur 6**, en 4, jw 1, es 1 | hi 60 | hi 60 |
| lines in Arabic/Urdu script | **9** (1232 characters) | 2 lines, 2 stray characters | 1 line, 1 stray character |
| WER / CER | 46.2 / 51.8 % | 32.6 / 23.4 % | **31.5 / 22.5 %** |

and on the real clips: hi<->ur flips 6 to 0, Arabic-script lines 5 to 0 (to 2 stray characters when forced).
20 % of the Hindi sentences were mis-detected (12 of 60: 6 as Urdu, 4 as English, 1 Javanese, 1 Spanish; 9 came out in Arabic script, 2 of the
English-labelled ones in Urdu script and the Javanese one as Latin gibberish), and every one of them was
fixed by restricting the choice. the {hi, en} limit is better than forcing `hi` on the real clips because it lets the English stretches
come out as English (`hinglish-zudio`, which is spoken English: forced `hi` made up Hindi ("इसे अगर पर पर देखते हैं"), {hi, en} wrote "It has grown 1200% in just the last 4 years.").
the lock removes the flipping, not whisper's own Hindi error: 31.5 % WER is still two and a half times Nemotron's.

forced `hi` is not airtight: two lines had a stray Arabic or Tamil letter inside Devanagari
(`सडकों पر ज्यாदा`). a post-check for non-Devanagari, non-Latin letters in a Hindi line is cheap and worth having.

## candidate B: what FluidAudio and NVIDIA actually ship

- FluidAudio v0.18.0 (2026-10-28) release notes: **Nemotron Unified ASR 0.6B** is 25 *European* languages
  (bg hr cs da nl en et fi fr de el hu it lv lt mt pl pt ro sk sl es sv ru uk): **no Hindi**. **Nemotron 3.5 Transcribe Lite** is
  the encoder and CTC timestamp head for meeting-length offline transcription (words with timings plus diarization), not
  a streaming Hindi model; not run.
- but 0.18.0 also contains `StreamingNemotronMultilingualAsrManager`, and the repo it downloads from,
  `FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML`, carries NVIDIA's `nemotron-3.5-asr-streaming-0.6b`
  (40 language-locales; Hindi is one of the 19 "transcription-ready" ones, with FLEURS Hindi WER in NVIDIA's card) as CoreML for the
  full 13,087-token vocabulary in `multilingual/{560,1120,2240,4480}ms`. the language is chosen by a prompt id (`hi-IN` = 6,
  `en-US` = 0, `auto` = 101, 121 entries in `metadata.json`). so a Hindi-capable streaming CoreML model **does** run in Swift
  with no porting: `downloadVariant(languageCode: "hi-IN", chunkMs: 1120)`, `loadModels`, `setLanguage("hi-IN")`, feed `[Float]`
  chunks, a callback with the whole line so far. the README's table only lists en es fr it pt de zh ja; Hindi works, was measured
  here, and is not in FluidAudio's own benchmark table.
- the repo is public (no gate despite a Discord note in its card), license OpenMDW-1.1 (commercial use allowed, keep the NVIDIA attribution).
- not tried: soniqo speech-swift, the other community CoreML builds (aufklarer, BarathwajAnandan), mlx and onnx ports. the FluidAudio path
  met every requirement so there was no reason to.
- cost: 640 MB per chunk-size bundle on disk; first load compiles for the neural engine (412 s for the first bundle including the download,
  68 s for the second); later loads take under a second.
- **upgrading the app from FluidAudio 0.15.5 to 0.18 is a real step** (this bench is a separate package). the app's other FluidAudio users (parakeet, Silero VAD, the diarizer) need re-checking.

## how English inside Hindi comes out (Hinglish)

Apple and Nemotron-with-`hi-IN` both write English words in **Devanagari** ("नाइंटी परसेंट रिटेंशन", "टीचिंग", "प्रोग्रेस"), the way
Hindi speakers type; Nemotron does it correctly and consistently, Apple makes more word errors ("दिस इस ए थे इस फाइव ओवरों" for "this is the five hours ..." where Nemotron has "इसकी
वैल्यू देस ए वेरी फेमस थ्योरी व्हिच इज कॉल्ड फाइव अवर रूल"). Nemotron `auto` keeps English runs in Latin when it hears them
as English ("That is very, very critical second thing which I do personally is मैं जो भी सीखता हूँ ...") and
whisper writes English words in Latin. 511 of 1233 words in whisper's real-clip output are Latin. which is better depends on the next stage:
Apple Translation on a Devanagari-transliterated English word is not measured (see below), and a Latin word is likely to pass through intact.
a mix of scripts inside a line is the price of `auto`. forcing `hi-IN` on an all-English clip (`hinglish-zudio`) turns it into Devanagari
sound-alikes ("इट इज़ ग्रोन ट्वेल्व हंड्रेड परसेंट इन जस्ट द लास्ट फोर ईयर्स"), faithful but unreadable as English: the lock must be per meeting and must allow English.

## translation (Hindi to English)

**not measured with Apple Translation.** `LanguageAvailability` says hi -> en is *supported* but **the Hindi pack is not installed on this mac**,
and a command-line tool cannot install it: macOS shows a consent sheet only from a view's `.translationTask`.
`hindi-bench install-translation` opens a small window that asks for it (it was run, timed out at 45 s with nobody to click Download).
**manual step for you:** System Settings > General > Language & Region > Translation Languages > Hindi (download), or run
`hindi-bench install-translation` and click Download. then `hindi-bench translate --from fleurs --n 150 --out ...` and
`translate --from <run.json>` measure per-sentence and six-word-prefix latency, and a unigram F1 against the English FLEURS sentence,
and keep rows for side-by-side samples. it is built and builds, but has never run to completion.

what was measured instead is **whisper large-v3 `task=translate`** (60 sentences, Hindi audio to English text in one pass): unigram F1
against the reference English 0.53, and plainly weak on proper nouns and idiom:

| FLEURS id | machine English (whisper translate) | reference English |
|---|---|---|
| 1984 | The reason for more traffic on the roads is a lot of car ownership, which has increased the development of new techniques in health care to improve the broken food in the body. | Mass car ownership also leads to a higher incidence of accidents on the roads, which leads to the invention of new techniques in healthcare for repairing damaged bodies. |
| 1831 | Plittwise National Park is surrounded by dense forests, mainly surrounded by beech, spruce and fir trees. Here you can find alpine and land-based forests. | The Plitvice Lakes national park is heavily forested, mainly with beech, spruce, and fir trees, and features a mixture of Alpine and Mediterranean vegetation. |
| 1667 | In common words, when the organiser starts to lead his full-fledged members, then two types of behaviors come to the fore. One of the spectrum's one line is trying to remain one of those boys or girls. | Generally speaking, two behaviors can emerge as managers begin to lead their former peers. One end of the spectrum is trying to remain "one of the guys" (or gals). |
| 1933 | Finally, many such small cats, including loose-bellied cats, eat many small creatures like ants, rodents, lizards and birds. | Finally, there are many small cats (including loose pet cats) that eat the far more numerous small prey like insects, rodents, lizards, and birds. |
| 1965 | This is mostly the soil where oil is considered unsafe. Among these, mostly the Pohu Kutba trees are overgrown. | They are almost all sandy beaches with safe swimming, and most have shade provided by pohutukawa trees. |
| 2005 | But there are many things about those birds that still look like dinosaurs. | But there are a lot of things about birds that still look like a dinosaur. |
| 1993 | Atlantic storm is the 10th storm of the season. The stormy and torrential storm Jerry has formed in the Atlantic Ocean today. | The tenth named storm of the Atlantic Hurricane season, Subtropical Storm Jerry, formed in the Atlantic Ocean today. |
| 1763 | Just like a pull on the moon earth causes a crack, the Milky Way also puts a pressure on the Milky Way. | Just like the moon exerts a pull on the earth, causing tides, so does the Milky Way exert a force on the Sagittarius galaxy. |
| 1873 | Do not ignore men and be ignorant of what you say. It is not right to have or not have cultural differences. | Be firm in turning down men, and don't be afraid to stand your ground (cultural differences or not, it doesn't make it ok!). |
| 1947 | Before the arrival of the pieces, the elephant had never faced any disease related problems since 1800s. | Prior to the arrival of troops, Haiti had not encountered problems related to the disease since the 1800s. |

(the Hindi for each is the FLEURS reference; pick them up from `/tmp/hindi-bench/fleurs/refs.json`, or run `scripts/analyze.py samples`.) so whisper's own
translation is not a fallback for the plan; it also needs the whole stretch decoded first. the plan's Apple Translation step is still the open question of phase 1.

## side by side, FLEURS Hindi (transcripts, 4 of the 10 sampled)

| | reference | Apple | Nemotron 1120 ms | whisper as the app | whisper {hi, en} |
|---|---|---|---|---|---|
| 1984 | सड़कों पर ज़्यादा दुर्घटना की वजह बहुत ज़्यादा कार ओनरशिप है, जिससे शरीर में हुई टूट-फूट को सुधारने के लिए हेल्थकेयर में नई तकनीकों के आविष्कार को बढ़ावा मिला है. | कोन पर ज़्यादा दुर्घटना की वजह बहुत ज़्यादा कार ओनरशिप है जिससे शरीर में हुई टूट को सुधारने के लिए हेल्थकेयर में नई तकनीकों के आविष्कार को बढ़ावा मिला है | सड़कों पर ज्यादा धुर्घटना की वजह बहुत ज्यादा कार ओनरशिप है, जिससे शरीर में हुई टूट फूट को सुधारने के लिए हेल्थकेयर में नई तकनीकों के आविष्कार को बढ़ावा मिला है | **سڑکوں پر زیادہ دھرکٹنا کی وجہ بہت زyادہ کار آنرشپ ہے ...** (Urdu script) | सडकों पر ज्यாदा ध्रुकटना की वज़ा बहृत ग्यादा कार ओनर्शिप है, जिससं शरीर में हुई ... (stray Arabic and Tamil letters) |
| 1993 | अटलांटिक तूफ़ान मौसम का दसवाँ तूफ़ान, उपोष्णकटिबंधीय तूफ़ान जेरी, आज अटलांटिक महासागर में बना है. | तूफ़ान मौसम दसवां तूफ़ान आज सागर में बना है | अटलांटिक तूफान मौसम का दसवां तूफान उपोष ने कटिबंधीय तूफान जेरी आज अटलांटिक महासागर में बना है | अट्लांटिक तुफान मौसम का दस्व तुफान उपोशन कटिबंदे चुफान जेरी आज अट्लांटिक महाशागर में बना है। | same |
| 1873 | पुरुषों को दृढ़ता से नकारें और अपनी बात पर बेहिचक अड़ी रहें (...). | पूर्ण को दृढ़ता से करें और अपनी बात पर बेहिचक आदि रहें ... | पुरुषों को दृढ़ता से नकारें और अपनी बात पर बेहिचक अड़ी रहें। सांस्कृतिक अंतरों के होने या नहीं होने से यह सही नहीं हो जाता | **پرشوں کو دلہتا سے نکاریں ...** (Urdu script) | पुरुषों को दिर्धिता से नकारें ... सही नहीं हो जाता झाल |
| 1947 | टुकड़ियों के पहुँचने से पहले, 1800 के दशक से हैती का ... | टुकड़ियाँ के पहुँचने से पहला थारा 100 के दशक से है ... | टुकड़ियों के पहुंचने से पहले अठारह सौ के दशक से हैती का कभी भी बीमारियों से जुड़ी समस्याओं से सामना नहीं हुआ था | टुकडियों के पहुचने से पहले 1800 के दशक से हैती का ... | same |

## not measured

- **Apple Translation, entirely** (pack not installed, above): latency, quality, the ten Apple samples.
- **CPU and neural-engine load** (needs `powermetrics`, which needs root). memory is the process's resident set only: the CoreML models run on the neural engine
  and a system service, so it understates real use (Apple's recogniser is not in it at all). no energy figure.
- **word-accurate latency.** it is estimated (README). no force alignment was done.
- **accuracy on real Hindi/Hinglish.** there are no references for the clips; what is said above about them is from reading the output.
  a Hinglish WER needs a hand-corrected transcript of at least one clip.
- **a clean whisper speed.** Low Power Mode was on; the app was running. run again with it off.
- Nemotron 560 ms and 4480 ms bundles, the `latin/` bundle, Nemotron 3.5 Transcribe Lite, other community builds, whisper turbo, Parakeet.
- speaker overlap, far-field or compressed call audio (the clips are clean YouTube audio; FLEURS is studio read speech). a meeting through a laptop
  speaker will be worse for every engine.

## risks

- **dependency bump.** Nemotron streaming needs FluidAudio >= 0.18 and its assets, the app is on 0.15.5.
- **a single-vendor chain**: FluidInference's CoreML conversion of NVIDIA's model, hosted on a repo whose card still says "join the Discord" for access (it
  downloaded without). pin the model revision and keep a copy.
- **the lock must exist for Nemotron too**: `hi-IN` on English speech writes Devanagari sound-alikes; `auto` is a language-ID the model does inside the
  decoder and let 30 characters of Arabic into one FLEURS sentence. pick `hi-IN` or `en-US` per meeting (the prompt id is changeable per stream).
- **size and first run**: 640 MB, several minutes to compile on the first use.
- **numbers as words, no inverse text normalisation**, and "हि" spelling variants that Hindi readers will notice.
- **the real clips are small** (8 min of speech) and only one of them (`hinglish-shamani`) is clean, genuine Hinglish.
- Apple's dictation asset is installed by the system; its Hindi model is the weak part, not the plumbing. it needs no speech permission in this tool
  (SpeechAnalyzer ran from a command-line binary), but an app may need `NSSpeechRecognitionUsageDescription`: not tested inside the app.

## what phase 2 should do

1. **add Nemotron 3.5 (1120 ms bundle, `hi-IN`) as the live engine for `them`**, behind the existing stretch transcriber, FluidAudio bumped to 0.18. feed it the
   same 100 ms chunks; show the callback's line dimmed, replace it in place; a quiet moment of ~0.6 s ends the line (the manager takes `reset()` between
   lines; `finish()` flushes). budget a model download and first-run compile screen.
2. **the language lock lives outside the engines.** score the first 20 to 30 s with whisper's language probabilities restricted to the languages the user hears
   (default en + hi, treating ur as hi), lock the leader for the meeting, and set Nemotron's prompt id to match (`hi-IN` or `en-US`); a switch needs ~30 s of evidence.
   also give the stretch transcriber that language: `{hi, en}` for detection or `language = hi`, never free detection. add the post-check: a line meant to be Hindi that
   contains Arabic-script letters is decoded again as Hindi.
3. **fix the saved transcript's speed** before trusting it on Hindi: temperature fallback is what turns a 15 s stretch into a minute. try
   `temperatureFallbackCount` 1 or 2 and a compression-ratio threshold that Devanagari does not trip, measure on a mac with Low Power Mode off.
4. **close the open question: install the Hindi pack and run `translate`** (README). decide on its numbers whether to translate the settled line only, or also a
   6-word tail every 0.7 s. if Apple Translation is weak on Devanagari-transliterated English, test it on Nemotron `auto` output (Latin English kept) too.
5. keep Apple's `DictationTranscriber` out of the design except as an optional "instant draft" while Nemotron's model is still downloading.
6. next measurements: a hand-corrected Hinglish clip for real WER, the 560 ms bundle, a call recorded through speakers, and CPU/ANE/energy with `powermetrics`.
