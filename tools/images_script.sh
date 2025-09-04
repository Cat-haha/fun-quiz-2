# ...existing code...
#!/usr/bin/env bash
set -euo pipefail

# images_script.sh
# Scans the workspace for i.postimg.cc image URLs, groups them by section
# (deduced from filenames like reading_section.html -> reading), downloads
# originals into assets/images/all/<section>/orig/, converts to AVIF only,
# and writes a mapping CSV. Use --apply to replace URLs in source files
# (creates .bak backups).
#
# This variant ensures postimg links from index.html's questions[] are
# extracted first, in array order (question image then feedbackImage),
# then appends links found elsewhere. The final ordering is preserved and
# used for naming/processing.

ROOT="$(pwd)"
OUT_ROOT="$ROOT/assets/images/all"
TMP_LIST="$(mktemp)"
APPLY=0
if [ "${1:-}" = "--apply" ]; then APPLY=1; fi

# Tools required
command -v sha1sum >/dev/null 2>&1 || { echo "sha1sum required (coreutils)" >&2; exit 1; }
AVIFENC=$(command -v avifenc || true)
CAVIF=$(command -v cavif || true)
FFMPEG=$(command -v ffmpeg || true)
if [ -z "$AVIFENC" ] && [ -z "$CAVIF" ] && [ -z "$FFMPEG" ]; then
  echo "ERROR: no AVIF encoder found (avifenc, cavif, or ffmpeg). Install one and retry." >&2
  exit 1
fi

mkdir -p "$OUT_ROOT"
MAP_CSV="$OUT_ROOT/postimg-mapping-by-section-avif.csv"
echo "\"original_url\",\"source_file\",\"section\",\"avif\"" > "$MAP_CSV"

echo "Scanning repository for i.postimg.cc URLs..."
# Build TMP_LIST so index.html's questions[] images come first (exact array order),
# then other files. Each line: <source_file><TAB><url>

# start with empty tmp
: > "$TMP_LIST"

# 1) extract ordered links from index.html questions[] (question then feedbackImage)
if [ -f "index.html" ]; then
  echo "Extracting ordered postimg links from index.html..."
  perl -0777 -ne '
    if ( /var\s+questions\s*=\s*\[(.*?)\];/s ) {
      $block = $1;
      # find top-level objects (simple balanced-brace heuristic)
      my $depth = 0;
      my $obj = "";
      foreach my $ch (split //, $block) {
        $obj .= $ch;
        if ($ch eq "{") { $depth++; next }
        if ($ch eq "}") { $depth-- }
        if ($depth == 0 && $obj =~ /^{.*}$/s) {
          # process single object
          if ( $obj =~ /"image"\s*:\s*"([^"]+)"/s ) { print "index.html\t$1\n"; }
          if ( $obj =~ /"feedbackImage"\s*:\s*"([^"]+)"/s ) { print "index.html\t$1\n"; }
          $obj = "";
        }
      }
      # If any trailing object (fallback)
      if ($obj =~ /"image"\s*:\s*"([^"]+)"/s) { print "index.html\t$1\n"; }
      if ($obj =~ /"feedbackImage"\s*:\s*"([^"]+)"/s) { print "index.html\t$1\n"; }
    }
  ' index.html >> "$TMP_LIST"
else
  echo "index.html not found, skipping ordered extraction."
fi

# 2) scan other files for i.postimg.cc links (append, skip index.html)
find . \
  -path ./node_modules -prune -o -path ./.git -prune -o -path "$OUT_ROOT" -prune -o \
  -type f \( -iname '*.html' -o -iname '*.htm' -o -iname '*.js' -o -iname '*.css' -o -iname '*.md' -o -iname '*.txt' -o -iname '*.json' \) -print0 \
  | while IFS= read -r -d '' file; do
      [ "$file" = "./index.html" ] && continue
      perl -0777 -ne 'while(/(https?:\/\/i\.postimg\.cc\/[A-Za-z0-9._%\/\-\+]+\.(?:png|jpg|jpeg|gif|webp|svg)(?:\?[^\s"'\''<>]*)?)/ig){ print "$ARGV\t".$1."\n" }' "$file" >> "$TMP_LIST" 2>/dev/null || true
    done

# 3) dedupe while preserving first occurrence (so index.html order remains)
TMP_DEDUP="$(mktemp)"
awk '!seen[$0]++' "$TMP_LIST" > "$TMP_DEDUP"
mv "$TMP_DEDUP" "$TMP_LIST"

echo "Collected $(wc -l < "$TMP_LIST" | tr -d ' ') postimg link(s) (ordered)."
echo "Preview (first 50 lines):"
head -n 50 "$TMP_LIST" | sed -n '1,50p'

# Proceed to download/convert in the collected order, naming per-section with incremental numbers
declare -A COUNTERS

process_section_name() {
  local file="$1"
  local base=$(basename "$file")
  local name="${base%.*}"
  # Treat index.html as the 'index' section
  if [[ "$name" == "index" ]]; then
    name="index"
  elif [[ "$name" == *_section ]]; then
    name="${name%_section}"
  fi
  local section
  section=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/_+/-/g; s/[^a-z0-9.-]+/-/g; s/-+/-/g; s/^-|-$//g')
  if [ -z "$section" ]; then
    section="unknown"
  fi
  printf '%s' "$section"
}

convert_to_avif() {
  local src="$1" dst="$2"
  if [ -n "$AVIFENC" ]; then
    "$AVIFENC" --min 0 --max 33 --speed 6 "$src" "$dst" >/dev/null 2>&1
    return $?
  fi
  if [ -n "$CAVIF" ]; then
    "$CAVIF" -q 75 -o "$dst" "$src" >/dev/null 2>&1
    return $?
  fi
  if [ -n "$FFMPEG" ]; then
    "$FFMPEG" -y -i "$src" -c:v libaom-av1 -crf 30 -b:v 0 -strict -2 "$dst" >/dev/null 2>&1
    return $?
  fi
  return 1
}

init_counter_for_section() {
  local section="$1"
  if [ -n "${COUNTERS[$section]:-}" ]; then return; fi
  local max=0
  if [ -d "$OUT_ROOT/$section" ]; then
    for f in "$OUT_ROOT/$section"/image-*.avif; do
      [ -e "$f" ] || continue
      local b num
      b=$(basename "$f")
      num=$(printf '%s' "$b" | sed -E 's/^image-([0-9]+)\.avif$/\1/')
      if [[ "$num" =~ ^[0-9]+$ ]]; then
        if [ "$num" -gt "$max" ]; then max="$num"; fi
      fi
    done
  fi
  COUNTERS[$section]="$max"
}

total=0
while IFS=$'\t' read -r src_file url; do
  [ -z "$url" ] && continue
  total=$((total+1))
  section=$(process_section_name "${src_file:-unknown}")
  target_dir="$OUT_ROOT/$section"
  orig_dir="$target_dir/orig"
  mkdir -p "$orig_dir" "$target_dir"

  clean_url="${url%%\?*}"
  orig_fname=$(basename "$clean_url")
  ext="${orig_fname##*.}"
  init_counter_for_section "$section"

  # find next available number (001...)
  while true; do
    next_num=$((COUNTERS[$section] + 1))
    pad=$(printf '%03d' "$next_num")
    orig_path="$orig_dir/image-${pad}.${ext}"
    avif_path="$target_dir/image-${pad}.avif"
    if [ -f "$avif_path" ] || [ -f "$orig_path" ]; then
      COUNTERS[$section]=$((COUNTERS[$section] + 1))
      continue
    fi
    COUNTERS[$section]="$next_num"
    break
  done

  echo "[$section] assigning image-${pad} for $url (from $src_file)"
  if [ -f "$avif_path" ]; then
    echo "Skipping existing: $avif_path"
  else
    if ! curl -sL --fail "$url" -o "$orig_path"; then
      echo "  failed to download $url" >&2
      COUNTERS[$section]=$((COUNTERS[$section] - 1))
      continue
    fi
    if ! convert_to_avif "$orig_path" "$avif_path"; then
      echo "  AVIF conversion failed for $orig_path" >&2
      rm -f "$orig_path" "$avif_path" || true
      COUNTERS[$section]=$((COUNTERS[$section] - 1))
      continue
    fi
  fi

  avif_rel="${avif_path#$ROOT/}"
  printf '%s\n' "\"$url\",\"$src_file\",\"$section\",\"$avif_rel\"" >> "$MAP_CSV"
done < "$TMP_LIST"

rm -f "$TMP_LIST"
echo "Processed $total links. Mapping: $MAP_CSV"
# ...existing code...
```// filepath: /workspaces/fun-quiz-2/tools/images_script.sh
# ...existing code...
#!/usr/bin/env bash
set -euo pipefail

# images_script.sh
# Scans the workspace for i.postimg.cc image URLs, groups them by section
# (deduced from filenames like reading_section.html -> reading), downloads
# originals into assets/images/all/<section>/orig/, converts to AVIF only,
# and writes a mapping CSV. Use --apply to replace URLs in source files
# (creates .bak backups).
#
# This variant ensures postimg links from index.html's questions[] are
# extracted first, in array order (question image then feedbackImage),
# then appends links found elsewhere. The final ordering is preserved and
# used for naming/processing.

ROOT="$(pwd)"
OUT_ROOT="$ROOT/assets/images/all"
TMP_LIST="$(mktemp)"
APPLY=0
if [ "${1:-}" = "--apply" ]; then APPLY=1; fi

# Tools required
command -v sha1sum >/dev/null 2>&1 || { echo "sha1sum required (coreutils)" >&2; exit 1; }
AVIFENC=$(command -v avifenc || true)
CAVIF=$(command -v cavif || true)
FFMPEG=$(command -v ffmpeg || true)
if [ -z "$AVIFENC" ] && [ -z "$CAVIF" ] && [ -z "$FFMPEG" ]; then
  echo "ERROR: no AVIF encoder found (avifenc, cavif, or ffmpeg). Install one and retry." >&2
  exit 1
fi

mkdir -p "$OUT_ROOT"
MAP_CSV="$OUT_ROOT/postimg-mapping-by-section-avif.csv"
echo "\"original_url\",\"source_file\",\"section\",\"avif\"" > "$MAP_CSV"

echo "Scanning repository for i.postimg.cc URLs..."
# Build TMP_LIST so index.html's questions[] images come first (exact array order),
# then other files. Each line: <source_file><TAB><url>

# start with empty tmp
: > "$TMP_LIST"

# 1) extract ordered links from index.html questions[] (question then feedbackImage)
if [ -f "index.html" ]; then
  echo "Extracting ordered postimg links from index.html..."
  perl -0777 -ne '
    if ( /var\s+questions\s*=\s*\[(.*?)\];/s ) {
      $block = $1;
      # find top-level objects (simple balanced-brace heuristic)
      my $depth = 0;
      my $obj = "";
      foreach my $ch (split //, $block) {
        $obj .= $ch;
        if ($ch eq "{") { $depth++; next }
        if ($ch eq "}") { $depth-- }
        if ($depth == 0 && $obj =~ /^{.*}$/s) {
          # process single object
          if ( $obj =~ /"image"\s*:\s*"([^"]+)"/s ) { print "./index.html\t$1\n"; }
          if ( $obj =~ /"feedbackImage"\s*:\s*"([^"]+)"/s ) { print "./index.html\t$1\n"; }
          $obj = "";
        }
      }
      # If any trailing object (fallback)
      if ($obj =~ /"image"\s*:\s*"([^"]+)"/s) { print "index.html\t$1\n"; }
      if ($obj =~ /"feedbackImage"\s*:\s*"([^"]+)"/s) { print "index.html\t$1\n"; }
    }
  ' index.html >> "$TMP_LIST"
else
  echo "index.html not found, skipping ordered extraction."
fi

# 2) scan other files for i.postimg.cc links (append, skip index.html)
find . \
  -path ./node_modules -prune -o -path ./.git -prune -o -path "$OUT_ROOT" -prune -o \
  -type f \( -iname '*.html' -o -iname '*.htm' -o -iname '*.js' -o -iname '*.css' -o -iname '*.md' -o -iname '*.txt' -o -iname '*.json' \) -print0 \
  | while IFS= read -r -d '' file; do
      [ "$file" = "./index.html" ] && continue
      perl -0777 -ne 'while(/(https?:\/\/i\.postimg\.cc\/[A-Za-z0-9._%\/\-\+]+\.(?:png|jpg|jpeg|gif|webp|svg)(?:\?[^\s"'\''<>]*)?)/ig){ print "$ARGV\t".$1."\n" }' "$file" >> "$TMP_LIST" 2>/dev/null || true
    done

# 3) dedupe while preserving first occurrence (so index.html order remains)
TMP_DEDUP="$(mktemp)"
awk '!seen[$0]++' "$TMP_LIST" > "$TMP_DEDUP"
mv "$TMP_DEDUP" "$TMP_LIST"

echo "Collected $(wc -l < "$TMP_LIST" | tr -d ' ') postimg link(s) (ordered)."
echo "Preview (first 50 lines):"
head -n 50 "$TMP_LIST" | sed -n '1,50p'

# Proceed to download/convert in the collected order, naming per-section with incremental numbers
declare -A COUNTERS

process_section_name() {
  local file="$1"
  local base=$(basename "$file")
  local name="${base%.*}"
  if [[ "$name" == *_section ]]; then name="${name%_section}"; fi
  local section
  section=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/_+/-/g; s/[^a-z0-9.-]+/-/g; s/-+/-/g; s/^-|-$//g')
  if [ -z "$section" ]; then
    section="unknown"
  fi
  printf '%s' "$section"
}

convert_to_avif() {
  local src="$1" dst="$2"
  if [ -n "$AVIFENC" ]; then
    "$AVIFENC" --min 0 --max 33 --speed 6 "$src" "$dst" >/dev/null 2>&1
    return $?
  fi
  if [ -n "$CAVIF" ]; then
    "$CAVIF" -q 75 -o "$dst" "$src" >/dev/null 2>&1
    return $?
  fi
  if [ -n "$FFMPEG" ]; then
    "$FFMPEG" -y -i "$src" -c:v libaom-av1 -crf 30 -b:v 0 -strict -2 "$dst" >/dev/null 2>&1
    return $?
  fi
  return 1
}

init_counter_for_section() {
  local section="$1"
  if [ -n "${COUNTERS[$section]:-}" ]; then return; fi
  local max=0
  if [ -d "$OUT_ROOT/$section" ]; then
    for f in "$OUT_ROOT/$section"/image-*.avif; do
      [ -e "$f" ] || continue
      local b num
      b=$(basename "$f")
      num=$(printf '%s' "$b" | sed -E 's/^image-([0-9]+)\.avif$/\1/')
      if [[ "$num" =~ ^[0-9]+$ ]]; then
        if [ "$num" -gt "$max" ]; then max="$num"; fi
      fi
    done
  fi
  COUNTERS[$section]="$max"
}

total=0
while IFS=$'\t' read -r src_file url; do
  [ -z "$url" ] && continue
  total=$((total+1))
  section=$(process_section_name "${src_file:-unknown}")
  target_dir="$OUT_ROOT/$section"
  orig_dir="$target_dir/orig"
  mkdir -p "$orig_dir" "$target_dir"

  clean_url="${url%%\?*}"
  orig_fname=$(basename "$clean_url")
  ext="${orig_fname##*.}"
  init_counter_for_section "$section"

  # find next available number (001...)
  while true; do
    next_num=$((COUNTERS[$section] + 1))
    pad=$(printf '%03d' "$next_num")
    orig_path="$orig_dir/image-${pad}.${ext}"
    avif_path="$target_dir/image-${pad}.avif"
    if [ -f "$avif_path" ] || [ -f "$orig_path" ]; then
      COUNTERS[$section]=$((COUNTERS[$section] + 1))
      continue
    fi
    COUNTERS[$section]="$next_num"
    break
  done

  echo "[$section] assigning image-${pad} for $url (from $src_file)"
  if [ -f "$avif_path" ]; then
    echo "Skipping existing: $avif_path"
  else
    if ! curl -sL --fail "$url" -o "$orig_path"; then
      echo "  failed to download $url" >&2
      COUNTERS[$section]=$((COUNTERS[$section] - 1))
      continue
    fi
    if ! convert_to_avif "$orig_path" "$avif_path"; then
      echo "  AVIF conversion failed for $orig_path" >&2
      rm -f "$orig_path" "$avif_path" || true
      COUNTERS[$section]=$((COUNTERS[$section] - 1))
      continue
    fi
  fi

  avif_rel="${avif_path#$ROOT/}"
  printf '%s\n' "\"$url\",\"$src_file\",\"$section\",\"$avif_rel\"" >> "$MAP_CSV"
done < "$TMP_LIST"

rm -f "$TMP_LIST"
echo "Processed $total links. Mapping: $MAP_CSV"
# ...existing code...