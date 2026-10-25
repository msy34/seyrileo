#!/usr/bin/env bash
# Generates the showcase catalogue's artwork and video (App Store screenshots, `-SeyrileoShowcase`).
# Everything is drawn from ffmpeg's lavfi generators with a system font: fictional titles,
# no third-party footage, posters, logos or artwork. Output: .../SeyrileoFixtureServer/Media/showcase
set -euo pipefail
OUT="$(cd "$(dirname "$0")/.." && pwd)/Packages/SeyrileoKit/Sources/SeyrileoFixtureServer/Media/showcase"
rm -rf "$OUT"; mkdir -p "$OUT"
FONT="/System/Library/Fonts/Avenir Next.ttc"
TMP="$(mktemp -d)"

# id | title (\n = line break) | colour 1 | colour 2 | colour 3
POSTERS=$(cat <<'LIST'
701|The Saffron\nLighthouse|0x1B2A6B|0xE39B3B|0x0B1030
702|Copper Kites|0x0E5C63|0xD9824B|0x081A2A
703|Tuesday\nthe Cat|0x2C1E5A|0xF0C27A|0x120B2A
704|Glass Orchard|0x14532D|0x9ED9B7|0x061A10
705|Seven Small\nHarbors|0x123A6B|0x6FC3DF|0x050E1F
706|The Winter\nTram|0x3A3F58|0xC9D6F0|0x101320
707|Paperlight|0x5A1E3A|0xF4A6A0|0x1E0A14
708|Hollow Bay|0x0C3B4A|0x48D5C1|0x04131A
801|Night Shift\nDiaries|0x1A1446|0x7D6BF2|0x07051A
802|The Lighthouse\nKitchen|0x5B2C0E|0xF2B463|0x1C0D04
803|Moonlit\nMarket|0x10284D|0xE7D7A8|0x050B18
804|Cat Café\nChronicles|0x3B2416|0xE0B48A|0x140B06
LIST
)

while IFS='|' read -r id title c1 c2 c3; do
  printf '%b' "$title" > "$TMP/$id.txt"
  # Poster 2:3 — night gradient, a soft glowing moon in the accent colour, title at the bottom.
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "gradients=size=600x900:c0=${c1}:c1=${c3}:nb_colors=2:x0=300:y0=0:x1=300:y1=900:type=linear:seed=$id" \
    -f lavfi -i "color=c=${c2}:s=600x900" \
    -frames:v 1 -filter_complex "[1]format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='255*exp(-((X-300)^2+(Y-320)^2)/14000)'[moon];\
[0][moon]overlay,format=yuv420p,\
drawtext=fontfile='${FONT}':textfile='$TMP/$id.txt':fontsize=62:fontcolor=0xFFF4E0:line_spacing=6:x=(w-text_w)/2:y=h-text_h-110:shadowcolor=black@0.6:shadowx=0:shadowy=3,\
drawbox=x=250:y=h-70:w=100:h=3:color=0xFFF4E0@0.7:t=fill" \
    -q:v 4 "$OUT/poster-$id.jpg"
  # Backdrop 16:9 (no text).
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "gradients=size=1280x720:c0=${c3}:c1=${c1}:c2=${c2}:nb_colors=3:x0=0:y0=720:x1=1280:y1=0:type=linear:seed=$id" \
    -frames:v 1 -q:v 5 "$OUT/backdrop-$id.jpg"
done <<< "$POSTERS"

# A calm, abstract video in the icon's colours: live loop (HLS, 10 × 2 s) and a VOD file.
GRAD="gradients=size=960x540:rate=25:c0=0x0B1030:c1=0x2340A8:c2=0x48D5C1:c3=0xE39B3B:c4=0x5B2C8E:nb_colors=5:speed=0.02:type=spiral"
mkdir -p "$OUT/live"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "$GRAD" \
  -f lavfi -i "sine=frequency=220:sample_rate=48000" -t 20 -filter:a "volume=0.02" \
  -c:v libx264 -profile:v main -preset veryfast -pix_fmt yuv420p -b:v 600k -maxrate 700k -bufsize 1200k \
  -g 50 -keyint_min 50 -sc_threshold 0 -r 25 -c:a aac -b:a 48k -ac 2 \
  -f hls -hls_time 2 -hls_list_size 0 -hls_segment_type mpegts -hls_playlist_type vod \
  -hls_segment_filename "$OUT/live/seg%d.ts" "$OUT/live/index.m3u8"
rm "$OUT/live/index.m3u8"
for i in $(seq 0 9); do ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT/live/seg$i.ts"; done > "$OUT/live/durations.txt"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "$GRAD" \
  -f lavfi -i "sine=frequency=220:sample_rate=44100" -t 240 -filter:a "volume=0.02" \
  -c:v libx264 -profile:v main -preset veryfast -pix_fmt yuv420p -crf 30 -g 50 -r 25 \
  -c:a aac -b:a 32k -ac 1 -movflags +faststart "$OUT/feature.mp4"
rm -rf "$TMP"
du -sh "$OUT"
