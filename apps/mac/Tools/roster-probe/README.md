# roster-probe

a developer tool, not part of the app. the meetings work wants to put a name on
every line of a transcript ("Priya: …", not "them 2: …") without a bot joining
the call. the plan is to read the call app's own window through the macOS
Accessibility API: who is in the call, and who is speaking right now. this tool
finds out what Zoom and Google Meet actually expose, from a real call, so the
reader in the app can be built on facts (track S2 in `PLAN-live-translation.md`;
S4 builds the readers from what this finds).

it reads, it never clicks or types. no dependencies, nothing leaves the mac.

## build

```
cd apps/mac/Tools/roster-probe
swift build -c release
alias rp=.build/release/roster-probe     # the examples below use the full path
```

## permission: Accessibility, for your terminal app

the tool reads other apps' windows, so macOS must allow the app that runs it:

1. System Settings › Privacy & Security › Accessibility
2. switch on your terminal app (Terminal, iTerm, Ghostty, Warp, or the editor
   whose terminal you use). add it with the + button if it is not listed.
3. quit and reopen the terminal app, then run the command again.

if it is missing, the tool says so and stops.

## privacy

dumps and logs hold participant names and on-screen text (chat, captions, tab
titles). they are written only to the path you give with `--out`, and by default
to `/tmp/roster-probe/` (the folder is created private, files `0600`). the repo
`.gitignore`s `*.json`, `*.jsonl` and `*.txt` in this folder anyway. never
commit them. if you send them to someone, replace the names first, for example
`sed -i '' 's/Priya Sharma/Person 1/g' file.jsonl` (the analysis does not care
what the names are).

## commands

```
roster-probe list [--all]
roster-probe dump  --app zoom|chrome|arc|safari|teams|<bundle id> [--window <title part>]
                   [--depth N] [--max-nodes N] [--budget SECONDS] [--no-enable] [--fixed-attrs] [--out file.json]
roster-probe watch --app … [--window <title part>] [--interval 0.25] [--seconds 120] [--tiles-only]
                   [--depth N] [--max-nodes N] [--no-enable] [--fixed-attrs] [--out file.jsonl]
roster-probe analyze file.jsonl [--spans N] [--out report.txt]
```

**`list`** shows the running call-capable apps (Zoom, Chrome, Arc, Safari, Teams,
Edge, Brave, Firefox, Webex, Slack, FaceTime) with pid, bundle id and every
window the Accessibility API can see: title, size, focused / main / minimized.
`--all` lists every app.

**`dump`** takes one full snapshot of the call window as JSON: for every node
the role, subrole, role description, title, description, value (cut at 300
characters), help, `AXIdentifier`, `AXDOMIdentifier`, `AXDOMClassList` (web
content), selected / focused / enabled, frame, and under `attrs` every other
simple attribute the node has (it asks each node for its attribute names, so an
attribute nobody expected still shows up). each node also carries its structural
path. nodes that look like a person's name are marked `nameGuess` and given a
`tile`. it prints a summary: node counts, web areas, the names it found.

- `--app` takes `zoom` (`us.zoom.xos`), `chrome`, `arc`, `safari`, `teams`
  (`com.microsoft.teams2`, or the old `com.microsoft.teams`), `edge`, `brave`,
  `firefox`, `webex`, `slack`, `facetime`, or any bundle id, or a unique part of
  the app's name. Microsoft Teams works the same way; it just was not installed
  when this was written.
- `--window` picks windows whose title contains the text, case-insensitive. a
  browser window's title is its active tab's title, so `--window Meet` finds a
  Google Meet tab that is in front. with no `--window`: windows whose title
  looks like a call (meet, meeting, zoom, teams, call, webex, huddle); else, for
  a browser, its focused window; else, for a native app, all its windows.
- `--depth` (default 80) and `--max-nodes` (default 40000) bound the walk,
  `--budget` (default 60 s) bounds the time. the summary says if anything was cut.
- `--fixed-attrs` skips the per-node attribute-name lookup. faster, and shows only
  the common attributes. use it only if a walk is too slow.

**`watch`** reads the window over and over (`--interval`, default 0.25 s, for
`--seconds`, default 120; Ctrl-C ends it early and the log is still complete)
and writes only what changed, one JSON line each, with `t` (seconds since start)
and `iso` (wall-clock time, so the lines line up with who was talking):

- `name`: a node whose text looks like a person's name appeared or went away
  (`present` true / false). "looks like a name": one to five words, each starting
  with a capital (or a letter with no case, so Devanagari works), no digits, not
  a UI word (Mute, Participants, Chat, …); a trailing `(Host)` / `(Me)` / `(You)`
  is ignored; a label like "Priya Sharma, Computer audio muted" gives the part
  before the comma. `You` / `Me` is marked `self`.
- `changed`: any attribute of any node changed, with `old` and `new`. position
  and size changes are reported as `position` / `size`. this is how the speaking
  indicator reveals itself: a class list, a description, a value, a selected flag.
- `appeared` / `disappeared`: a node came or went. an indicator that is drawn
  only while someone speaks shows up this way.
- every event about a node inside a participant's **tile** carries `tile` (the
  name), `tilePath` and `rel`. a tile is the largest ancestor of a name node that
  holds that one name and no other (and at most 400 nodes), so it is the
  participant's tile in the gallery or the row in the participant list, without
  the tool knowing what Zoom or Meet look like. `rel` is the node's path inside
  it, so the same indicator on different people has the same `rel`.
- `tick` every 5 s (and printed to the terminal), `bulk` if a sample changed more
  than 400 things (a panel opened, tiles moved), `muted` for an attribute that
  changes constantly (clocks), `start` / `end` with the sample count and how long
  one read took.

it also writes `<out>.baseline.json`, the dump of the first sample.
`--tiles-only` logs only changes inside a tile (smaller log). leave it off for
the first call, so nothing is filtered away.

one read of the whole tree takes a few tens of milliseconds for a small page and
can take seconds for a busy Meet or Zoom window. `end` records the median; if it
is above the interval, the real rate is that.

**`analyze`** reads a watch log and prints:

- coverage: duration, samples, read time, whether the tree was cut;
- **names**: every name-like text, how long it was on screen, and where;
- **labels that change who they name**: one node whose text goes Priya → Rahul →
  Priya … (Zoom's speaker view, or a "currently speaking" strip);
- **attributes that toggled inside a participant's tile**, ranked. for each
  `(attribute, role, path inside the tile)`: the values it took and for how long,
  which value is the rarer one (taken as "active"), how many names it toggled for,
  per name the changes and the active spans with clock times, and how often two
  names were active at once. a speaking indicator looks like: toggles for 2+
  names, a small share of time active per name, almost never two at once
  (`LIKELY`);
- toggles outside any tile (a border around the whole window, a status line);
- the stable things to target: the node that holds the name (role, attribute,
  path inside the tile, DOM classes and ids) and the indicator candidate.

## how the tree gets populated (and what that touches)

- **Chrome, Arc and other Chromium browsers, and Electron apps** build the page's
  accessibility tree only when they believe an assistive tool is running. the tool
  asks them by setting `AXEnhancedUserInterface` and `AXManualAccessibility` on the
  app. Chrome accepts the first (it answers with an error code even when it works,
  so the tool reads the value back); Arc and Electron apps take the second.
  `--no-enable` leaves them alone.
- the tool reads each flag first, sets it only if it was off, and **puts it back
  when it ends**, including on Ctrl-C. if the tool is killed hard (`kill -9`, the
  terminal closing) the flag stays on until the browser restarts; that does no harm
  beyond a little extra work in the browser.
- **Safari** needs nothing. **Zoom** is a native app and exposes its UI without
  help; the flags are set on it too (harmless) and `--no-enable` turns that off.
- the first read of a browser waits up to about 5 s for the page's web area to
  fill in.
- **the call window must be visible.** Chromium drops a page's tree when its
  window is covered by other windows, minimised, or on another Space. while the
  call is on screen it works, whether or not the browser is the active app. the
  terminal that runs the tool has to be somewhere else: a second display, or a
  small window beside the call. the same goes for Zoom, so do not cover the
  Zoom window. the `dump` says "the page's accessibility tree is empty" when this
  happens.
- in a browser, name candidates are taken only from inside the web page, not from
  the toolbar and tabs.
- Safari, Chrome and Arc were checked against a local mock of tiles with a
  toggling class (see the end of this file). Zoom's meeting window, Meet itself and
  Teams have not been seen yet: that is what the real call is for.

## the real call: Zoom

you need a call with at least two other people who can talk when asked. use a
second display for the terminal if you have one, or put the terminal in a small
window that does not cover the Zoom window. nothing in the tool needs the terminal
to be in front.

1. build the tool and grant Accessibility (above). join the call as usual.
2. in Zoom: View › **Gallery** (the green/grey tile grid), full size or a large
   window, not covered. turn on View › Show names (on by default). open
   **Participants** (the button in the bar) and leave the panel open, so the tool can
   see the list as well as the tiles. do not share your screen.
3. in the terminal:
   ```
   cd apps/mac/Tools/roster-probe
   .build/release/roster-probe list
   ```
   you should see `zoom.us` with a window called "Zoom Meeting" (and maybe a
   Participants window). note the exact titles.
4. snapshot while everyone is **silent**:
   ```
   .build/release/roster-probe dump --app zoom --out /tmp/roster-probe/zoom-silent.json
   ```
   the summary lists the names it found. if it finds none, try
   `--window "Zoom Meeting"` and say so in your report.
5. start the log (2.5 minutes), then run the speaking script below:
   ```
   .build/release/roster-probe watch --app zoom --interval 0.25 --seconds 150 --out /tmp/roster-probe/zoom-watch.jsonl
   ```
6. snapshot again while **one person is mid-sentence** (ask someone to count slowly
   to twenty, run this in the middle of it), and note who it was:
   ```
   .build/release/roster-probe dump --app zoom --out /tmp/roster-probe/zoom-speaking.json
   ```
7. then:
   ```
   .build/release/roster-probe analyze /tmp/roster-probe/zoom-watch.jsonl --out /tmp/roster-probe/zoom-report.txt
   ```
8. repeat step 5 once in **speaker view** (View › Speaker), as
   `--out /tmp/roster-probe/zoom-speaker-watch.jsonl`, with the same script, shorter
   (`--seconds 90`). speaker view marks the speaker differently.

## the real call: Google Meet (Chrome, Arc, Safari)

do it once per browser you care about (Chrome first, then Arc, then Safari), in a
real Meet call with two or more others.

1. join the call in the browser. the call tab must be the **active tab** of its
   window, the window visible and not covered (the window title is the tab title,
   which is why the tool finds it with `--window Meet`; Meet's tab title is
   usually "Meet – abc-defg-hij"). set the layout to **Tiles** (More options ›
   Change layout › Tiles), not Auto or Spotlight. open **People** in the side
   panel and leave it open. do not present.
2. in the terminal:
   ```
   cd apps/mac/Tools/roster-probe
   .build/release/roster-probe list
   ```
   find the browser window whose title is the call.
3. silent snapshot (use `--app chrome`, `--app arc` or `--app safari`):
   ```
   .build/release/roster-probe dump --app chrome --window Meet --out /tmp/roster-probe/meet-chrome-silent.json
   ```
   it must print `web areas: 1` or more and the names of the others. if it says the
   tree is empty, the window is covered or the call is not the active tab; fix that
   and run it again.
4. the log:
   ```
   .build/release/roster-probe watch --app chrome --window Meet --interval 0.25 --seconds 150 --out /tmp/roster-probe/meet-chrome-watch.jsonl
   ```
   and the speaking script below.
5. a snapshot in the middle of someone talking, as in Zoom step 6
   (`meet-chrome-speaking.json`).
6. `analyze` as in Zoom step 7 (`meet-chrome-report.txt`).

Meet draws the speaking indicator as an animated element (moving bars or a pulsing
ring on the tile, and a border). it may appear as a class on a node, as a node
that exists only while that person speaks, or not at all. the log has all of those.

## the speaking script (the 150 seconds of `watch`)

start the stopwatch the moment `watch` prints "reading …". ask everyone to follow it
(read the times from a clock; `analyze` prints clock times too):

- 0:00 to 0:10 everyone silent, mic on (no one muted yet).
- then each other person in turn talks for about 10 seconds ("count to twenty
  slowly" works), with 5 seconds of silence between people. A, then B, then C, then
  A, B, C again. you also talk once, for 10 seconds, in the middle.
- once, two people talk at the same time for about 5 seconds.
- once, one person mutes for 10 seconds and unmutes, and one person turns their
  camera off for 10 seconds and back on.
- write down the order and rough clock times, with the names as they appear in the
  call. the analysis is checked against that.

## what to send back

for each of Zoom (gallery), Zoom (speaker view), Meet in Chrome, Meet in Arc, Meet in
Safari that you tried (the browsers can be sent later):

- the report: `…-report.txt`
- the log: `…-watch.jsonl` and `…-watch.baseline.json`
- the two dumps: `…-silent.json` and `…-speaking.json`
- your notes: who spoke when (the order above), the app and version (Zoom
  Workplace version; Chrome / Arc / Safari version), which Zoom layout and Meet layout
  you used, and anything odd (the tool said the tree was empty, a window was covered,
  a name looked wrong)

the files contain names and on-screen text. replace the names first if you want to
(see privacy). the whole folder is `/tmp/roster-probe/`.

if there is no trace of a speaking indicator in the report, say so and send the
files anyway: that result matters as much as a hit. the follow-up for that is
reading the speaking state from the call's audio levels instead.

## limits and known gaps

- the name heuristic is a guess for finding candidates, not the final parser. it can
  miss names written in all lower case and can pick up single capitalised words
  that are really UI labels; the report marks single words as `possible`.
- tiles are found from names. a participant whose name is not on screen (a tile
  with only a picture) has no tile, so events inside it are listed as outside any tile.
- Zoom's custom-drawn video tiles may expose their name only in the participant
  list, or only in the window's description. the report says where names were found.
- the web tree is a copy of what the page tells the accessibility layer; Meet may
  change its DOM at any time. S4 reads the roster from these dumps, so re-run this
  after a big Meet or Zoom update.

## what was checked without a call

the machine this was written on had no call. checked against local pages instead
(`/tmp/roster-probe-test/meet-mock.html`: three tiles with names, an inner
indicator element whose class and `aria-label` toggle every 1.5 s, and a
speaker-view mock whose label text changes):

- Chrome 156, Arc 1.170 and Safari 26.5.2 all populate the AXWebArea tree, including
  `AXDOMIdentifier` and `AXDOMClassList`. Chrome needs `AXEnhancedUserInterface`
  (set and restored by the tool) and its window visible; Arc worked through
  `AXManualAccessibility`; Safari needed neither. all three expose `aria-label` as
  both `AXTitle` and `AXDescription`.
- `watch` + `analyze` find the three names, the toggling class (`tile` →
  `tile speaking`) and the toggling indicator description for all three names with no
  overlap, and the changing speaker-view label, in all three browsers.
- the Zoom app's Login window (no sign-in done) is readable: buttons and text areas.
  its meeting window was not seen (Zoom 5.15.11 is what is installed here).
