#!/usr/bin/env bash
# Regenerates the original, synthetic fixture media used by Seyrileo's fixture mode.
# All output is produced from ffmpeg's built-in lavfi generators (test patterns and tones):
# no third-party footage, logos or artwork. See docs/adr/0005-fixture-mode.md.
set -euo pipefail
OUT="$(cd "$(dirname "$0")/.." && pwd)/Packages/SeyrileoKit/Sources/SeyrileoFixtureServer/Media"
rm -rf "$OUT"; mkdir -p "$OUT"

make_channel() { # name, video-filter source, tone frequency, [audio codec]
  local name=$1 video=$2 freq=$3 acodec=${4:-aac} dir="$OUT/$1"
  mkdir -p "$dir"
  ffmpeg -hide_banner -loglevel error \
    -f lavfi -i "$video" \
    -f lavfi -i "sine=frequency=${freq}:beep_factor=4:sample_rate=48000" \
    -t 20 -filter:a "volume=0.08" \
    -c:v libx264 -profile:v main -preset veryfast -pix_fmt yuv420p -b:v 280k -maxrate 320k -bufsize 600k \
    -g 50 -keyint_min 50 -sc_threshold 0 -r 25 \
    -c:a "$acodec" -b:a 64k -ac 2 \
    -f hls -hls_time 2 -hls_list_size 0 -hls_segment_type mpegts -hls_playlist_type vod \
    -hls_segment_filename "$dir/seg%d.ts" "$dir/index.m3u8"
  rm "$dir/index.m3u8" # the fixture server writes live sliding-window playlists itself
  # Exact per-segment durations so generated #EXTINF values are truthful.
  for i in $(seq 0 9); do
    ffprobe -v error -show_entries format=duration -of csv=p=0 "$dir/seg$i.ts"
  done > "$dir/durations.txt"
}

make_channel pattern-a "testsrc2=size=640x360:rate=25" 330
make_channel pattern-b "smptehdbars=size=640x360:rate=25,drawbox=x=mod(t*120\,640):y=150:w=60:h=60:color=0x48D5C1@0.9:t=fill" 523
# Same as real Turkish broadcast restreams: HLS with MPEG-1 Layer II audio, which AVPlayer cannot decode.
make_channel pattern-mp2 "testsrc2=size=640x360:rate=25,hue=s=0" 392 mp2
# A raw (non-HLS) MPEG-TS file for the compatibility matrix: Xtream ".ts" output format.
cat "$OUT"/pattern-a/seg{0..3}.ts > "$OUT/raw-pattern-a.ts"
# On-demand fixtures (Milestone 3): a 3-minute progressive MP4 (long enough for resume and
# "continue watching" rules) and a short MKV (container AVFoundation does not play).
VOD="$OUT/vod"; mkdir -p "$VOD"
vod_src() { echo "smptebars=size=320x180:rate=15,drawbox=x=mod(t*40\,300):y=80:w=20:h=20:color=0x48D5C1@0.9:t=fill"; }
ffmpeg -hide_banner -loglevel error -f lavfi -i "$(vod_src)" \
  -f lavfi -i "sine=frequency=262:beep_factor=8:sample_rate=44100" -t 180 -filter:a "volume=0.06" \
  -c:v libx264 -profile:v main -preset veryfast -pix_fmt yuv420p -crf 32 -g 30 \
  -c:a aac -b:a 32k -ac 1 -movflags +faststart "$VOD/feature.mp4"
ffmpeg -hide_banner -loglevel error -f lavfi -i "$(vod_src)" -t 10 \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p -crf 32 "$VOD/short.mkv"
# Multi-language MP4 (audio + subtitle choice and its memory): English/Turkish audio and subtitles.
SUBS="$(mktemp -d)"
printf '1\n00:00:00,500 --> 00:00:19,500\nEnglish subtitle\n' > "$SUBS/en.srt"
printf '1\n00:00:00,500 --> 00:00:19,500\nTürkçe altyazı\n' > "$SUBS/tr.srt"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "smptebars=size=320x180:rate=15" \
  -f lavfi -i "sine=frequency=440:sample_rate=44100" -f lavfi -i "sine=frequency=660:sample_rate=44100" \
  -i "$SUBS/en.srt" -i "$SUBS/tr.srt" -t 20 -map 0:v -map 1:a -map 2:a -map 3 -map 4 \
  -c:v libx264 -profile:v main -preset veryfast -pix_fmt yuv420p -crf 34 -g 30 -c:a aac -b:a 24k -ac 1 -c:s mov_text \
  -metadata:s:a:0 language=eng -metadata:s:a:0 title=English -metadata:s:a:1 language=tur -metadata:s:a:1 title=Turkish \
  -metadata:s:s:0 language=eng -metadata:s:s:1 language=tur -disposition:a:0 default -disposition:a:1 0 \
  -disposition:s:0 0 -disposition:s:1 0 -movflags +faststart "$VOD/multilang.mp4"
ls -la "$OUT" "$OUT"/pattern-a "$VOD" | head -40
du -sh "$OUT"
