#!/bin/bash
# Replays a directory of seg_NNNNN.ts files against a YouTube HLS ingest URL
# using exactly the ESSegmentUploader delivery pattern: POST segment, then
# POST an updated media.m3u8 with a 5 segment rolling window, 2 s cadence.
set -u
DIR="$1"
BASE="$2"   # full ingest URL ending in file=
SEGS=($(ls "$DIR" | grep -E '^seg_[0-9]+\.ts$' | sort))
COUNT=${#SEGS[@]}
echo "pushing $COUNT segments from $DIR"

for i in $(seq 0 $((COUNT - 1))); do
  SEG=${SEGS[$i]}
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: video/mp2t" \
    --data-binary @"$DIR/$SEG" "${BASE}${SEG}")
  echo "$(date +%H:%M:%S) $SEG -> $CODE"

  # rolling playlist, 5 entry window, matching the app byte for byte
  START=$((i >= 4 ? i - 4 : 0))
  PLAYLIST="#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:2
#EXT-X-MEDIA-SEQUENCE:$START"
  for j in $(seq $START $i); do
    PLAYLIST="$PLAYLIST
#EXTINF:2.000,
${SEGS[$j]}"
  done
  PCODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/vnd.apple.mpegurl" \
    --data-binary "$PLAYLIST" "${BASE}media.m3u8")
  echo "$(date +%H:%M:%S) media.m3u8 (seq $START..$i) -> $PCODE"
  sleep 2
done
echo "done"
