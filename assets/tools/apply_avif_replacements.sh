#!/usr/bin/env bash
set -euo pipefail

# Replace original i.postimg.cc URLs in source files with the local AVIF path.
# Uses the mapping CSV produced by tools/images_script.sh.
# Replacements use a relative path from the source file to the AVIF file.
#
# Usage:
#   chmod +x tools/apply_avif_replacements.sh
#   ./tools/apply_avif_replacements.sh
#
# Each modified file gets a .bak backup.

ROOT="$(pwd)"
MAP_CSV="$ROOT/assets/images/all/postimg-mapping-by-section-avif.csv"

if [ ! -f "$MAP_CSV" ]; then
  echo "Mapping CSV not found: $MAP_CSV" >&2
  exit 1
fi

echo "Applying AVIF replacements using mapping: $MAP_CSV"

# Use Python to safely parse the CSV and emit tab-separated lines:
python3 - "$MAP_CSV" <<'PY' | while IFS=$'\t' read -r original_url source_file section avif_rel; do
import sys, csv
csvfile = open(sys.argv[1], newline='', encoding='utf-8')
r = csv.reader(csvfile)
next(r, None)
for row in r:
    if len(row) < 4: continue
    # row: original_url, source_file, section, avif
    print("\t".join(row[:4]))
csvfile.close()
PY
  # trim whitespace
  original_url="${original_url#"${original_url%%[![:space:]]*}"}"
  original_url="${original_url%"${original_url##*[![:space:]]}"}"
  source_file="${source_file#"${source_file%%[![:space:]]*}"}"
  source_file="${source_file%"${source_file##*[![:space:]]}"}"
  avif_rel="${avif_rel#"${avif_rel%%[![:space:]]*}"}"
  avif_rel="${avif_rel%"${avif_rel##*[![:space:]]}"}"

  [ -z "$original_url" ] && continue
  [ -z "$source_file" ] && continue
  [ -z "$avif_rel" ] && continue

  # Resolve target source file
  # allow "./index.html" or "index.html" forms
  candidates=("$ROOT/$source_file" "$source_file" "./$source_file")
  target=""
  for c in "${candidates[@]}"; do
    if [ -f "$c" ]; then
      target="$c"
      break
    fi
  done
  if [ -z "$target" ]; then
    echo "Warning: source file not found, skipping: $source_file" >&2
    continue
  fi

  # Resolve absolute path to avif file
  avif_abs="$avif_rel"
  # If mapping stored a relative path (no leading /) make absolute relative to ROOT
  if [[ "$avif_abs" != /* ]]; then
    avif_abs="$ROOT/$avif_rel"
  fi
  if [ ! -f "$avif_abs" ]; then
    echo "Warning: AVIF file not found, skipping replacement for $original_url -> $avif_abs" >&2
    continue
  fi

  # Compute relative path from the source file directory to the avif file
  src_dir="$(dirname "$target")"
  relpath="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$avif_abs" "$src_dir")"

  echo "Replacing in $target"
  echo "  $original_url -> $relpath"

  # Make a .bak copy only once per file (Perl -i.bak will create .bak for every run; keep that behavior)
  # Use Perl with \Q...\E quoting to safely replace literal URL occurrences.
  ORIG="$original_url" REPL="$relpath" \
    perl -0777 -i.bak -pe 's/\Q$ENV{ORIG}\E/$ENV{REPL}/g' "$target"

done

echo