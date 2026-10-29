#!/usr/bin/env python3
"""extras `hindi-bench score` does not print, from the run json files.

  analyze.py flicker run.json [--limit N]     how often a shown word is later changed
  analyze.py samples run.json [run2.json ...] [--n 10] [--only prefix]   side by side lines
  analyze.py empty run.json                   stretches that came out empty
  analyze.py clips run.json [...]             per clip: stretches, languages, Arabic-script lines, language flips
  analyze.py translate-f1 run.json            unigram F1 of whisper's task=translate text against the English reference
"""
import json, sys, unicodedata, re, random

def load(p): return json.load(open(p))

def flicker(path, limit=None):
    d = load(path); res = d["results"][:limit] if limit else d["results"]
    shown = changed = 0; revisions = 0; caps_total = 0
    for r in res:
        caps = r["captions"]
        if len(caps) < 2: continue
        final = r["finalText"].split()
        seen = {}                       # index -> first text shown
        for c in caps:
            ws = c["text"].split()
            for i, w in enumerate(ws):
                seen.setdefault(i, w)
        for i, w in seen.items():
            shown += 1
            if i >= len(final) or final[i] != w: changed += 1
        # captions whose text is not an extension of the previous one
        prev = []
        for c in caps:
            ws = c["text"].split()
            caps_total += 1
            if prev and ws[:len(prev)] != prev: revisions += 1
            prev = ws
    print(f'{d["engine"]}: {changed}/{shown} words ({100*changed/max(shown,1):.1f} %) were different from the first time they were shown; '
          f'{revisions}/{caps_total} caption updates rewrote earlier text ({100*revisions/max(caps_total,1):.1f} %)')

def samples(paths, n=10, only=None, seed=3):
    runs = [load(p) for p in paths]
    rows = list(zip(*[r["results"] for r in runs]))
    if only: rows = [t for t in rows if t[0]["unit"]["id"].startswith(only)]
    rows = [t for t in rows if t[0]["finalText"].strip()]
    random.Random(seed).shuffle(rows)
    for t in rows[:n]:
        u = t[0]["unit"]
        print(f'--- {u["id"]} ({u["seconds"]:.1f} s)')
        if u.get("refHi"): print("  ref   :", u["refHi"])
        for run, r in zip(runs, t):
            print(f'  {run["engine"][:26]:26}: [{r.get("language") or "-"}] {r["finalText"]}')

def empty(path):
    d = load(path)
    e = [r for r in d["results"] if not r["finalText"].strip()]
    print(d["engine"], len(e), "of", len(d["results"]), "empty:", [(r["unit"]["id"], round(r["unit"]["seconds"], 1)) for r in e])

ARABIC = re.compile("[\u0600-\u06FF\u0750-\u077F\uFB50-\uFDFF\uFE70-\uFEFF]")

def clips(path):
    d = load(path); by = {}
    for r in d["results"]: by.setdefault(r["unit"]["clip"], []).append(r)
    print(d["engine"])
    tot_flips = tot_hiur = tot_tr = 0
    for clip, rs in by.items():
        rs.sort(key=lambda r: r["unit"]["start"])
        langs = [r.get("language") for r in rs]
        flips = sum(1 for a, b in zip(langs, langs[1:]) if a and b and a != b)
        hiur = sum(1 for a, b in zip(langs, langs[1:]) if {a, b} == {"hi", "ur"})
        ar = sum(1 for r in rs if ARABIC.search(r["finalText"]))
        count = {}
        for l in langs: count[l or "-"] = count.get(l or "-", 0) + 1
        tot_flips += flips; tot_hiur += hiur; tot_tr += ar
        print(f"  {clip:20} stretches {len(rs):3}  langs {count}  flips {flips}  hi<->ur {hiur}  arabic-script lines {ar}")
    print(f"  total flips {tot_flips}, hi<->ur {tot_hiur}, arabic-script lines {tot_tr}")

def translate_f1(path):
    d = load(path)
    def toks(s): return re.findall(r"[a-z0-9']+", s.lower())
    f1s = []
    for r in d["results"]:
        ref, hyp = toks(r["unit"].get("refEn") or ""), toks(r.get("translated") or "")
        if not ref or not hyp: continue
        c = {}
        for w in ref: c[w] = c.get(w, 0) + 1
        o = 0
        for w in hyp:
            if c.get(w, 0) > 0: o += 1; c[w] -= 1
        p, q = o / len(hyp), o / len(ref)
        f1s.append(0 if o == 0 else 2 * p * q / (p + q))
    print(d["engine"], "translate task: mean unigram F1", round(sum(f1s) / len(f1s), 3), "over", len(f1s))

if __name__ == "__main__":
    a = sys.argv[1:]
    cmd = a.pop(0)
    opts = {}; files = []
    while a:
        x = a.pop(0)
        if x.startswith("--"): opts[x[2:]] = a.pop(0)
        else: files.append(x)
    if cmd == "flicker":
        for f in files: flicker(f, int(opts["limit"]) if "limit" in opts else None)
    elif cmd == "samples": samples(files, int(opts.get("n", 10)), opts.get("only"))
    elif cmd == "clips":
        for f in files: clips(f)
    elif cmd == "translate-f1":
        for f in files: translate_f1(f)
    elif cmd == "empty":
        for f in files: empty(f)
