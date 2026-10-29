#!/bin/zsh
# the five real clips used in REPORT.md, into /tmp/hindi-bench/real (never committed).
# needs uv (for yt-dlp) and macOS afconvert. ffmpeg is not needed.
set -u
mkdir -p /tmp/hindi-bench/real && cd /tmp/hindi-bench/real
for pair in uogcA8UyKYc:hindi-monologue 93lVnMTX9UY:hinglish-shamani R5sG2V5ICYo:hinglish-zudio \
            B6HuENuUEVg:hindi-meeting Ojd7thq8koE:hinglish-casual; do
  id=${pair%%:*}; name=${pair##*:}
  uvx yt-dlp -q -f "140/bestaudio[ext=m4a]/bestaudio" -o "$name.%(ext)s" "https://www.youtube.com/watch?v=$id"
  src=$(ls $name.* | grep -v '\.wav$' | head -1)
  afconvert -f WAVE -d LEF32@16000 -c 1 "$src" "$name.wav" && rm "$src"
done
ls -la
