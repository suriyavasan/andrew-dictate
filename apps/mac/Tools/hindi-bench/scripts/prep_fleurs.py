#!/usr/bin/env python3
"""FLEURS hi_in test -> 16 kHz mono wavs + refs.json (Hindi + parallel English).

usage: uv run --with pyarrow scripts/prep_fleurs.py --hi hi.parquet --en en.parquet --out /tmp/hindi-bench/fleurs --n 150
"""
import argparse, io, json, os, subprocess, random
import pyarrow.parquet as pq

ap = argparse.ArgumentParser()
ap.add_argument("--hi", required=True); ap.add_argument("--en", required=True)
ap.add_argument("--out", required=True); ap.add_argument("--n", type=int, default=150)
a = ap.parse_args()

hi = pq.read_table(a.hi).to_pylist()
en = {r["id"]: r for r in pq.read_table(a.en, columns=["id", "transcription", "raw_transcription"]).to_pylist()}
print("hi rows", len(hi), "en rows", len(en), "columns", list(hi[0].keys()))
seen = set(); rows = []
for r in hi:  # one recording per sentence id; ids are parallel across FLEURS languages
    if r["id"] in en and r["id"] not in seen:
        seen.add(r["id"]); rows.append(r)
print("parallel rows", len(rows))
random.Random(7).shuffle(rows)
rows = rows[: a.n]
os.makedirs(a.out + "/wav", exist_ok=True)
out = []
for r in rows:
    wav = f'{a.out}/wav/{r["id"]}.wav'
    if not os.path.exists(wav):
        # FLEURS ships 16 kHz mono wav; convert with afconvert (ffmpeg is not needed) to 32-bit float.
        raw = wav + ".src"
        open(raw, "wb").write(r["audio"]["bytes"])
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEF32@16000", "-c", "1", raw, wav], check=True)
        os.remove(raw)
    out.append({"id": r["id"], "wav": wav,
                "hi": r.get("raw_transcription") or r["transcription"],
                "hi_norm": r["transcription"],
                "en": en[r["id"]].get("raw_transcription") or en[r["id"]]["transcription"],
                "seconds": r.get("num_samples", 0) / 16000})
json.dump(out, open(a.out + "/refs.json", "w"), ensure_ascii=False, indent=1)
print("wrote", len(out), "utterances,", sum(o["seconds"] for o in out) / 60, "min")
