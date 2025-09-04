#!/usr/bin/env bash
set -euo pipefail

# Extract question/feedback images from index.html's questions array, download, convert to AVIF, and order as 001-question, 001-feedback, etc.

INDEX_HTML="index.html"
OUT_DIR="assets/images/quiz"
MAP_CSV="$OUT_DIR/quiz-image-mapping.csv"
mkdir -p "$OUT_DIR/orig" "$OUT_DIR/avif"

AVIFENC=$(command -v avifenc || true)
CAVIF=$(command -v cavif || true)
FFMPEG=$(command -v ffmpeg || true)
if [ -z "$AVIFENC" ] && [ -z "$CAVIF" ] && [ -z "$FFMPEG" ]; then
  echo "ERROR: no AVIF encoder found (avifenc, cavif, ffmpeg)" >&2
  exit 1
fi

echo "\"order\",\"type\",\"original_url\",\"local_avif\"" > "$MAP_CSV"

# Extract questions array block
awk '/var questions = \[/{flag=1; next} /];/{flag=0} flag' "$INDEX_HTML" > /tmp/questions_block.js

# Parse image URLs in order (question image, then feedbackImage for each question)
count=1
while read -r line; do
  # Extract question image
  img=$(echo "$line" | grep -o '"image": *"https://i\.postimg\.cc[^"]*"' | sed 's/.*"\(https:\/\/i\.postimg\.cc[^"]*\)".*/\1/')
  if [ -n "$img" ]; then
    pad=$(printf "%03d" "$count")
    fname="$OUT_DIR/orig/${pad}-question.$(basename "$img" | awk -F. '{print $NF}')"
    avifname="$OUT_DIR/avif/${pad}-question.avif"
    if [ ! -f "$avifname" ]; then
      echo "Downloading question $count: $img"
      curl -sL "$img" -o "$fname"
      # Convert to AVIF
      if [ -n "$AVIFENC" ]; then
        avifenc --min 0 --max 33 --speed 6 "$fname" "$avifname"
      elif [ -n "$CAVIF" ]; then
        cavif -q 75 -o "$avifname" "$fname"
      else
        ffmpeg -y -i "$fname" -c:v libaom-av1 -crf 30 -b:v 0 -strict -2 "$avifname"
      fi
    fi
    echo "\"$pad\",\"question\",\"$img\",\"$avifname\"" >> "$MAP_CSV"
  fi

  # Extract feedback image
  fimg=$(echo "$line" | grep -o '"feedbackImage": *"https://i\.postimg\.cc[^"]*"' | sed 's/.*"\(https:\/\/i\.postimg\.cc[^"]*\)".*/\1/')
  if [ -n "$fimg" ]; then
    pad=$(printf "%03d" "$count")
    fname="$OUT_DIR/orig/${pad}-feedback.$(basename "$fimg" | awk -F. '{print $NF}')"
    avifname="$OUT_DIR/avif/${pad}-feedback.avif"
    if [ ! -f "$avifname" ]; then
      echo "Downloading feedback $count: $fimg"
      curl -sL "$fimg" -o "$fname"
      # Convert to AVIF
      if [ -n "$AVIFENC" ]; then
        avifenc --min 0 --max 33 --speed 6 "$fname" "$avifname"
      elif [ -n "$CAVIF" ]; then
        cavif -q 75 -o "$avifname" "$fname"
      else
        ffmpeg -y -i "$fname" -c:v libaom-av1 -crf 30 -b:v 0 -strict -2 "$avifname"
      fi
    fi
    echo "\"$pad\",\"feedback\",\"$fimg\",\"$avifname\"" >> "$MAP_CSV"
  fi

  count=$((count+1))
done < <(grep -E '"question":|"image":|"feedbackImage":' /tmp/questions_block.js | paste - - -)

echo "Done. AVIFs in $OUT_DIR/avif/, mapping CSV: $MAP_CSV"