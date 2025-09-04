#!/usr/bin/env bash
set -u

# This script processes each quiz question in order, extracting image, feedbackImage, and hintImage (if present),
# then downloads and converts each to .avif, one at a time, in strict question order.
# Usage: ./tools/convert_quiz_images_per_question.sh

INDEX_HTML="index.html"
OUT_DIR="assets/images/quiz_per_question"
mkdir -p "$OUT_DIR/orig" "$OUT_DIR/avif"

# Extract URLs from questions array in strict question order: image, feedbackImage, hintImage
awk '/var questions = \[/, /];/ {
    if ($0 ~ /{/) {
        img=""; fb=""; hint="";
    }
    if ($0 ~ /feedbackImage:/) {
        match($0, /feedbackImage:\s*"([^"]+)"/, arr);
        if (arr[1] ~ /^https:\/\/i.postimg.cc\//) fb=arr[1];
    }
    if ($0 ~ /hintImage:/) {
        match($0, /hintImage:\s*"([^"]+)"/, arr);
        if (arr[1] ~ /^https:\/\/i.postimg.cc\//) hint=arr[1];
    }
    if ($0 ~ /},/) {
        if (img!="") print img;
        if (fb!="") print fb;
        if (hint!="") print hint;
    }
}' "$INDEX_HTML" > "$OUT_DIR/ordered_urls.txt"

count=1
echo '"original_url","image_file","status"' > "$OUT_DIR/mapping.csv"

while read -r url; do
  if [[ "$url" != https://* ]]; then
    continue
  fi
  pad=$(printf "%03d" "$count")
  orig_path="$OUT_DIR/orig/image-${pad}"
  avif_path="$OUT_DIR/avif/image-${pad}.avif"

  echo "Processing image #$pad"
  echo "Downloading $url -> $orig_path"
  if ! curl -sL --fail "$url" -o "$orig_path"; then
    echo "Download failed for $url"
    echo "\"$url\",\"image-${pad}.avif\",download_failed" >> "$OUT_DIR/mapping.csv"
    count=$((count + 1))
    continue
  fi

  echo "Converting $orig_path -> $avif_path"
  if ! ffmpeg -y -i "$orig_path" -c:v libaom-av1 -crf 30 -b:v 0 -strict -2 "$avif_path"; then
    echo "Conversion failed for $orig_path"
    echo "\"$url\",\"image-${pad}.avif\",conversion_failed" >> "$OUT_DIR/mapping.csv"
    count=$((count + 1))
    continue
  fi

  echo "\"$url\",\"image-${pad}.avif\",success" >> "$OUT_DIR/mapping.csv"
  count=$((count + 1))
done < "$OUT_DIR/ordered_urls.txt"

echo "Done. AVIF images are in $OUT_DIR/avif/ and mapping in $OUT_DIR/mapping.csv"
