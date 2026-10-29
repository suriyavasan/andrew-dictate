# plan: live translation and an apple-native app

the fork's next body of work, written 2026-10-29. each phase has a purpose, a
deliverable and a bar it must clear before the next one starts. planning and
review happen here; implementation is delegated phase by phase.

## why

at work, people who speak Hindi drift into Hindi mid-meeting and the rest of the
room is lost. the app already hears every call without a bot, keeps the audio and
writes a transcript — but its live view waits for a pause (up to 25 s of
monologue) and whisper re-guesses the language each stretch, so Hindi comes out
as Urdu and flips line to line. people asking for this kind of tool want, in
order: words as they are spoken (1–2 s is good, 5 s tolerable, 10 s useless),
the original with English beneath it, captions that do not flicker, a saved
bilingual record, and it working in every app rather than one platform.

## principles

- **hindi first.** quality on Hindi and Hinglish beats breadth of languages.
- **one language per meeting, per speaker.** never re-decided per sentence.
- **the live view is a second engine.** the stretch transcriber stays the
  accurate saved transcript; the live engine only drives what you watch.
- **on-device by default.** a cloud engine is opt-in, bring your own key.
- **apple-native everywhere.** SF Pro, system colours and accent, sentence case,
  light and dark following the system, native controls and materials. no gold,
  no custom fonts, no forced dark, no lowercase brand copy.

## speakers by name — built before phase 2 (2026-10-29)

**purpose:** a transcript that says *who* said what, by name, so the user and
every AI agent they work with (Claude Code and the like) read "Priya: …", not
"them 2: …". no bot joins the call; nothing leaves the mac.

where names come from, strongest first:

1. **the call app's own window, through accessibility** (already granted for
   paste): Zoom's tiles and participant list, Google Meet / Teams in a browser.
   the speaking highlight, sampled a few times a second *only while a meeting
   records* and only from the call's app, tells who is talking now. aligning those
   intervals with the diarizer's clusters names each cluster; a live line takes
   whoever was highlighted while it was spoken.
2. **remembered voices.** once a cluster has a name (from 1 or by hand), its
   voice embedding is kept on this mac and recognises them in later meetings, in
   any app. a setting turns it off; every voice can be forgotten.
3. **by hand.** click a speaker label in the meetings window (and later the live
   panel) to name it; the file and the voice are updated.
4. **you** are your name (settings, default the mac account's full name).
5. later: calendar attendees for spelling, and names said aloud ("thanks, Rahul")
   as a hint for the summary.

**for agents:**
- the saved markdown carries names on every turn and a `participants` list in
  the front matter.
- while a meeting records, the app appends each line (time, name, text, later
  the English) to a live feed file an agent can follow.
- a bundled MCP server (`andrew-dictate-mcp`, stdio) lists, reads and searches
  meetings and reads the live one; settings › meetings shows the one command
  that adds it to Claude Code.

tracks:

- **S1 — names, voices, rename, transcript format** (no call needed).
- **S2 — accessibility probe** (`Tools/roster-probe`): dumps what Zoom, Meet in
  Chrome / Arc / Safari expose while the user is in a real call. needs the user
  to run it in one or two calls.
- **S3 — agents:** the live feed and the MCP server.
- **S4 — roster readers** for Zoom and Meet built from S2's dumps; automatic
  naming from the speaking highlight, live and at the end.

**bar:** in a real Zoom and a real Meet call with three people, every line of
the saved transcript carries the right name, live lines carry it within a
couple of seconds, and Claude Code can answer "what did Priya ask for?" through
the MCP server.

## phase 1 — engine test (purpose: choose the live Hindi engine on numbers)

a developer tool, `Tools/hindi-bench`, beside `meeting-bench`. it streams Hindi
audio at real-time pace through each candidate and measures:

- time to first partial text, and to final text, after each word is spoken
- accuracy (WER and CER against references, Devanagari-normalised)
- language stability: how often the detected language changes, how often Hindi
  is written in Urdu script
- Hindi→English translation latency and quality (Apple Translation)
- CPU / ANE load, memory, model download size

candidates:

| | engine | why |
|---|---|---|
| A | Apple `DictationTranscriber`, `hi-IN`, volatile results | on-device, live partials, a fixed locale cannot flip |
| B | NVIDIA Nemotron streaming via FluidAudio ≥ 0.18 (or a CoreML build) if a Hindi-capable model exists | likely better on Indian English and Hinglish |
| C | WhisperKit large-v3, as the app runs it today (auto-detect per stretch) | the baseline that reproduces the Urdu flip |
| C′ | the same, language forced to `hi` and limited to {hi, en} | shows what the lock alone fixes |

audio: FLEURS `hi_in` (read speech, with parallel English references) and real
conversational Hindi and Hinglish clips (meetings, podcasts), never committed.

**bar:** a written report with a recommended engine, and the evidence for it.

## phase 2 — live engine and language lock

- the far side (`them`) is fed to the chosen streaming engine beside the stretch
  transcriber. partial text shows dimmed and is replaced in place; settled text
  is confirmed.
- **language lock.** a "languages I hear" setting (default: English + Hindi)
  limits detection to those. the first ~20–30 s of speech are scored together and
  the leader is locked for the meeting; a switch needs ~30 s of sustained
  evidence, never one line. Hindi and Urdu count as one language, written in
  Devanagari (likewise Malay/Indonesian, Serbian/Croatian/Bosnian). a Hindi line
  that comes out in Arabic script is decoded again as Hindi. Hinglish is Hindi
  with English words, not a switch. later, one lock per speaker.
- **translation.** settled text is translated to English with Apple Translation
  (on-device); the growing partial is re-translated at most every ~0.7 s, tail
  only. the AI provider is an optional fallback for Hinglish it handles badly.
- per-side choice: translate them, leave you as spoken (default).

**bar:** on the phase-1 audio, captions within ~1 s and English within ~2 s of
speech, zero Urdu-script lines and zero language flips with the lock on.

## phase 3 — apple-native redesign of the whole app

every surface, one design system: the live transcript panel, the meetings
window, settings, the menu-bar panel, the hud pill, onboarding, about, removal,
the dictionary and history.

- **type:** SF Pro (system font) and SF Mono only where a value is code-like;
  the HIG text styles (title, headline, body, callout, caption) instead of fixed
  sizes; sentence case for every title, label and button.
- **colour:** semantic system colours (label, secondaryLabel, separator,
  controlBackground), the user's system accent for selection and primary
  actions, system red for recording and destructive actions. the gold palette
  and `BrandUI` tints go.
- **materials:** standard window backgrounds and the system's Liquid Glass /
  vibrancy materials as macOS 26 draws them; light and dark follow the system;
  Reduce Transparency and Increase Contrast respected.
- **controls:** `Form` with `.formStyle(.grouped)`, `LabeledContent`, native
  `Toggle`, `Picker` (radio groups instead of hand-drawn cards), `Button` roles
  and styles, SF Symbols.
- **settings:** a System Settings–style sidebar (`NavigationSplitView`) —
  General, Dictation, AI, Meetings, Languages & translation, Dictionary, History.
- **live panel:** original line with English beneath, partial text dimmed, the
  language chip (`Hindi · locked`, click to pin another or turn translation off),
  adjustable text size, two modes — the floating panel (default) and a subtitle
  strip along the bottom of the screen; still hidden from screen capture.
- **meetings window:** standard sidebar / list / detail, system fonts and
  colours throughout, the transcript bilingual when it was translated.
- the fonts in `Sources/Resources/Fonts` and the brand components are removed
  once nothing uses them. the `ui-raycast` worktree is superseded.

**bar:** no custom font, no hard-coded colour outside the app icon, every
window correct in light, dark, and with Reduce Transparency on.

## phase 4 — bilingual saved transcript

the saved markdown keeps the original and the English for translated lines;
summaries read the English. the end-of-meeting transcript uses the locked
language instead of re-detecting.

## phase 5 — beyond Hindi, and more

other languages through the same lock and translation path; live speaker labels
(them 1, them 2); an opt-in cloud engine (Sarvam / Deepgram) for Tamil and other
languages with no on-device streaming model; translate what you said into their
language to paste in the chat; live captions for any audio, not just meetings.
