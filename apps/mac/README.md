# andrew dictate (mac app)

the app's source. the product is described in the repo's top-level README; the behaviour is in [SPEC.md](SPEC.md), the words in [GLOSSARY.md](GLOSSARY.md).

## use your meetings from an agent

the app ships a small read-only mcp server, `andrew-dictate-mcp`, so an agent such as Claude Code knows what was said in your meetings and by whom, the ones saved and the one recording now. it reads this mac only; nothing is sent anywhere.

settings › meetings › use with AI agents shows the command and copies it. it is:

```sh
claude mcp add andrew-dictate -- "/Applications/Andrew Dictate.app/Contents/Helpers/andrew-dictate-mcp"
```

(a development build is `Andrew Dictate Dev.app` and adds itself as `andrew-dictate-dev`.) the server finds your save folder in the app's preferences. pass `--bundle-id <id>` to read another build's.

| tool | what it gives |
|---|---|
| `list_meetings {limit?, since?, query?}` | id, title, app, started, duration, participants, speakers; newest first |
| `get_meeting {id, format?}` | the markdown (front matter, notes, transcript), or `format: "turns"` for `[{at, speaker, text}]` |
| `search_meetings {query, speaker?, limit?}` | turns that say every word, with meeting, time and speaker |
| `get_live_meeting {after_seq?}` | whether a meeting is recording, who is named so far, and its lines after `after_seq` (poll with `last_seq`) |

speaker names come from the call app's window, from voices you have named and the app remembers, or from naming a speaker by hand. `them`, `them 2` mean nobody is named yet.

the live meeting is also a file you can follow: `~/Library/Application Support/Andrew Dictate/live/current.jsonl`, one json object per line (`start`, one per settled line, `end`). the last twenty are kept.

## build and test

```sh
xcodegen generate
xcodebuild -project AndrewDictate.xcodeproj -scheme AndrewDictate -configuration Debug test -destination 'platform=macOS'
```

the server is its own target (`andrew-dictate-mcp`, sources in `MCP/`), embedded in the app by a copy-files phase. its reader and json-rpc are in `MCP/Server/` and are tested with the app's tests.
