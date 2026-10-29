#!/bin/zsh
# every measured run, one after another (they share the neural engine, so never in parallel).
# usage: scripts/run-all.sh [out-dir]    (default /tmp/hindi-bench/runs)
# FLEURS: the first 60 utterances for the cross-engine comparison (Nemotron also all 150).
# real clips: the first 120 s of each, cut into VAD stretches by `hindi-bench cut`.
set -u
cd "$(dirname "$0")/.."
B=.build/release/hindi-bench
OUT=${1:-/tmp/hindi-bench/runs}
mkdir -p $OUT
$B cut --seconds 180

# B: Nemotron 3.5, language hi-IN, 2.24 s and 1.12 s chunks; and with language auto
$B run --engine nemo --chunk-ms 2240 --set fleurs --n 150 --out $OUT/nemo2240-fleurs150.json
$B run --engine nemo --chunk-ms 2240 --set real --seconds 120 --out $OUT/nemo2240-real.json
$B run --engine nemo --chunk-ms 1120 --set fleurs --n 150 --out $OUT/nemo1120-fleurs150.json
$B run --engine nemo --chunk-ms 1120 --set real --seconds 120 --out $OUT/nemo1120-real.json
$B run --engine nemo --chunk-ms 2240 --lang auto --set fleurs --n 60 --out $OUT/nemoauto2240-fleurs.json
$B run --engine nemo --chunk-ms 2240 --lang auto --set real --seconds 120 --out $OUT/nemoauto2240-real.json

# A: Apple DictationTranscriber hi-IN, wall-clock pace
$B run --engine apple --set fleurs --n 60 --out $OUT/apple-fleurs.json
$B run --engine apple --set real --seconds 120 --out $OUT/apple-real.json

# C, C': whisper large-v3 as the app runs it, language forced, language limited to {hi, en}
$B run --engine whisper --mode auto --translate --set fleurs --n 60 --out $OUT/whisper-auto-fleurs.json
$B run --engine whisper --mode auto --set real --seconds 120 --out $OUT/whisper-auto-real.json
$B run --engine whisper --mode hi --set fleurs --n 60 --out $OUT/whisper-hi-fleurs.json
$B run --engine whisper --mode hi --set real --seconds 120 --out $OUT/whisper-hi-real.json
$B run --engine whisper --mode hien --set fleurs --n 60 --out $OUT/whisper-hien-fleurs.json
$B run --engine whisper --mode hien --set real --seconds 120 --out $OUT/whisper-hien-real.json
echo ALL DONE
