#!/usr/bin/env bash
set -euo pipefail

# images_script.sh
# Scans the workspace for i.postimg.cc image URLs, groups them by section
# (deduced from filenames like reading_section.html -> reading), downloads
# originals into assets/images/all/<section>/orig/, converts to AVIF only,
# and writes a mapping CSV. Use --apply to replace URLs in source files
# (creates .bak backups).

# Usage:
#   ./tools/images_script.sh         # generate AVIF files + mapping
#   ./tools/images_script.sh --apply # also replace URLs in source files (.bak)

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
# Extract pairs: source-file <tab> url
while IFS= read -r -d '' file; do
  # use perl to extract all postimg URLs from each file and print: <file>\t<url>
  perl -0777 -ne 'while(/(https?:\/\/i\.postimg\.cc\/[A-Za-z0-9._%\/\-\+]+\.(?:png|jpg|jpeg|gif|webp|svg)(?:\?[^\s"<>]*)?)/ig){ print "$ARGV\t".$1."\n" }' "$file" >> "$TMP_LIST" 2>/dev/null || true
done < <(find . -path ./node_modules -prune -o -path ./.git -prune -o -path "$OUT_ROOT" -prune -o -type f \( -iname '*.html' -o -iname '*.htm' -o -iname '*.js' -o -iname '*.css' -o -iname '*.md' -o -iname '*.txt' -o -iname '*.json' \) -print0)

if [ ! -s "$TMP_LIST" ]; then
  echo "No i.postimg.cc URLs found." >&2
  rm -f "$TMP_LIST"
  exit 0
fi

# dedupe by file+url
sort -u "$TMP_LIST" -o "$TMP_LIST"

echo "Found $(wc -l < "$TMP_LIST" | tr -d ' ') url references."

process_section_name() {
  local file="$1"
  local base
  base=$(basename "$file")
  local name="${base%.*}"
  # strip _section suffix if present
  if [[ "$name" == *_section ]]; then
    name="${name%_section}"
  fi
  # normalize to lowercase, underscores -> hyphens, remove unsafe chars
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

while IFS=$'\t' read -r src_file url; do
  [ -z "$url" ] && continue
  # determine section from source file; fallback to 'unknown' if empty
  section=$(process_section_name "${src_file:-unknown}")
  target_dir="$OUT_ROOT/$section"
  orig_dir="$target_dir/orig"
  mkdir -p "$orig_dir" "$target_dir"

  clean_url="${url%%\?*}"
  orig_fname=$(basename "$clean_url")
  ext="${orig_fname##*.}"
  url_hash=$(printf '%s' "$url" | sha1sum | awk '{print substr($1,1,8)}')
  safe_base=$(printf '%s' "$orig_fname" | sed -E 's/[^A-Za-z0-9._-]+/-/g' | sed "s/\.$ext$//")-$url_hash
  orig_path="$orig_dir/${safe_base}.${ext}"
  avif_path="$target_dir/${safe_base}.avif"

  if [ -f "$avif_path" ]; then
    echo "Skipping existing: $section/${safe_base}.avif"
  else
    echo "Downloading -> section: $section : $url"
    if ! curl -sL --fail "$url" -o "$orig_path"; then
      echo "  failed to download $url" >&2
      continue
    fi
    echo "  Converting to AVIF -> ${section}/${safe_base}.avif"
    if ! convert_to_avif "$orig_path" "$avif_path"; then
      echo "  AVIF conversion failed for $orig_path" >&2
      continue
    fi
  fi

  avif_rel="${avif_path#$ROOT/}"
  printf '%s\n' "\"$url\",\"$src_file\",\"$section\",\"$avif_rel\"" >> "$MAP_CSV"
done < "$TMP_LIST"

rm -f "$TMP_LIST"
echo "Done. Mapping: $MAP_CSV"

if [ "$APPLY" -eq 1 ]; then
  echo "Applying replacements in source files (creating .bak backups)..."
  python3 - <<'PY'
import csv,os,re,sys
root=os.getcwd()
mapf=os.path.join(root,'assets/images/all/postimg-mapping-by-section-avif.csv')
if not os.path.exists(mapf):
    print('Mapping not found', mapf, file=sys.stderr); sys.exit(1)
mapping={}
with open(mapf, newline='', encoding='utf-8') as f:
    r=csv.reader(f)
    next(r,None)
    for row in r:
        orig=row[0]
        avif=row[3]
        if avif:
            mapping[orig]=avif
files=[]
for dp,dirs,fns in os.walk(root):
    if any(skip in dp for skip in [os.path.join(root,'.git'), os.path.join(root,'node_modules'), os.path.join(root,'assets','images')]):
        continue
    for fn in fns:
        if fn.lower().endswith(('.html','.htm','.js','.css','.md','.txt','.json')):
            files.append(os.path.join(dp,fn))
for p in files:
    try:
        with open(p,'r',encoding='utf-8') as fh:
            txt=fh.read()
    except Exception:
        continue
    orig_txt=txt
    for orig,avif in mapping.items():
        pattern=re.escape(orig.split('?')[0])+r'(?:\?[^"]*)?'
        txt=re.sub(pattern,avif,txt)
    if txt!=orig_txt:
        open(p+'.bak','w',encoding='utf-8').write(orig_txt)
        open(p,'w',encoding='utf-8').write(txt)
        print('Updated',p)
print('Replacements done.')
PY
  echo "Replacement pass complete. Inspect .bak files if needed."
fi

echo "All finished. AVIF files are under assets/images/all/<section>/"
#!/usr/bin/env bash
set -euo pipefail

# Scan repo, download i.postimg.cc images, convert to AVIF only, group by section.
# Usage:
#   ./tools/convert_all_postimg_by_section_avif.sh        # create AVIFs + mapping
#   ./tools/convert_all_postimg_by_section_avif.sh --apply   # also replace URLs in source files (.bak backups)

ROOT="$(pwd)"
OUT_ROOT="$ROOT/assets/images/all"
TMP_LIST="$(mktemp)"
APPLY=0
if [ "${1:-}" = "--apply" ]; then APPLY=1; fi

# Tools
command -v sha1sum >/dev/null 2>&1 || { echo "sha1sum (coreutils) is required"; exit 1; }
AVIFENC=$(command -v avifenc || true)
CAVIF=$(command -v cavif || true)
FFMPEG=$(command -v ffmpeg || true)

if [ -z "$AVIFENC" ] && [ -z "$CAVIF" ] && [ -z "$FFMPEG" ]; then
  echo "ERROR: no AVIF encoder found. Install libavif-bin (avifenc), cavif, or ffmpeg."
  echo "On Ubuntu: sudo apt update && sudo apt install -y libavif-bin ffmpeg"
  exit 1
fi

mkdir -p "$OUT_ROOT"

echo "Scanning repository for i.postimg.cc URLs..."
find . \
  -path ./node_modules -prune -o -path ./.git -prune -o -path "$OUT_ROOT" -prune -o \
  -type f \( -iname '*.html' -o -iname '*.htm' -o -iname '*.js' -o -iname '*.css' -o -iname '*.md' -o -iname '*.txt' -o -iname '*.json' \) -print0 \
  | while IFS= read -r -d '' file; do
      perl -0777 -ne 'while(/(https?:\/\/i\.postimg\.cc\/[A-Za-z0-9._%\/\-\+]+\.(?:png|jpg|jpeg|gif|webp|svg)(?:\?[^\s"'\''<>]*)?)/ig){ print $ARGV,"\t",$1,"\n" }' "$file" \
        >> "$TMP_LIST" 2>/dev/null || true
    done

if [ ! -s "$TMP_LIST" ]; then
  echo "No i.postimg.cc URLs found."
  rm -f "$TMP_LIST"
  exit 0
fi

# dedupe pairs
sort -u "$TMP_LIST" > "${TMP_LIST}.uniq"
mv "${TMP_LIST}.uniq" "$TMP_LIST"

MAP_CSV="$OUT_ROOT/postimg-mapping-by-section-avif.csv"
echo "\"original_url\",\"source_file\",\"section\",\"avif\"" > "$MAP_CSV"

# Derive section name from filename like reading_section.html, brain_teasers.html, etc.
process_section_name() {
  local file="$1"
  local base=$(basename "$file")
  local name="${base%.*}"   # strip extension
  # If ends with _section, drop that suffix (reading_section -> reading)
  if [[ "$name" =~ _section$ ]]; then
    name="${name%_section}"
  fi
  # Replace underscores with hyphens, remove unsafe chars, collapse hyphens
  section=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/_+/-/g; s/[^a-z0-9.-]+/-/g; s/-+/-/g; s/^-|-$//g')
  # Fallback: if empty use parent directory name (sanitized)
  if [ -z "$section" ]; then
    parent=$(basename "$(dirname "$file")")
    section=$(echo "$parent" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9.-]+/-/g; s/-+/-/g; s/^-|-$//g')
    [ -z "$section" ] && section="unknown"
  fi
  printf '%s' "$section"
}

convert_to_avif() {
  local src="$1"
  local dst="$2"
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

while IFS=$'\t' read -r src_file url; do
  [ -z "$url" ] && continue
  section=$(process_section_name "$src_file")
  target_dir="$OUT_ROOT/$section"
  orig_dir="$target_dir/orig"
  mkdir -p "$orig_dir" "$target_dir"

  clean_url="${url%%\?*}"
  orig_fname="$(basename "$clean_url")"
  ext="${orig_fname##*.}"
  url_hash="$(printf "%s" "$url" | sha1sum | awk '{print substr($1,1,8)}')"
  safe_base="$(printf "%s" "$orig_fname" | sed -E 's/[^A-Za-z0-9._-]+/-/g' | sed "s/\.$ext$//")-$url_hash"
  orig_path="$orig_dir/${safe_base}.${ext}"
  avif_path="$target_dir/${safe_base}.avif"

  if [ -f "$avif_path" ]; then
    echo "Skipping existing: $section/${safe_base}.avif"
  else
    echo "Downloading -> section: $section : $url"
    if ! curl -sL --fail "$url" -o "$orig_path"; then
      echo "  failed to download $url" >&2
      continue
    fi

    echo "  Converting to AVIF -> ${section}/${safe_base}.avif"
    if ! convert_to_avif "$orig_path" "$avif_path"; then
      echo "  AVIF conversion failed for $orig_path" >&2
      continue
    fi
  fi

  avif_rel="${avif_path#$ROOT/}"
  printf '%s\n' "\"$url\",\"$src_file\",\"$section\",\"$avif_rel\"" >> "$MAP_CSV"
done < "$TMP_LIST"

rm -f "$TMP_LIST"
echo "Done. Mapping: $MAP_CSV"

if [ "$APPLY" -eq 1 ]; then
  echo "Applying replacements in source files (creating .bak backups)..."
  python3 - <<'PY'
import csv,os,re,sys
root = os.getcwd()
map_file = os.path.join(root, "assets/images/all/postimg-mapping-by-section-avif.csv")
if not os.path.exists(map_file):
    print("Mapping CSV not found:", map_file); sys.exit(1)
mapping = {}
with open(map_file, newline='', encoding='utf-8') as f:
    reader = csv.reader(f)
    next(reader, None)
    for row in reader:
        orig = row[0]
        avif = row[3]
        if avif:
            mapping[orig] = avif

files = []
for dirpath, dirnames, filenames in os.walk(root):
    if any(skip in dirpath for skip in [os.path.join(root,'.git'), os.path.join(root,'node_modules'), os.path.join(root,'assets','images')]):
        continue
    for fn in filenames:
        if fn.lower().endswith(('.html','.htm','.js','.css','.md','.txt','.json')):
            files.append(os.path.join(dirpath,fn))

for path in files:
    try:
        with open(path, 'r', encoding='utf-8') as f:
            txt = f.read()
    except Exception:
        continue
    orig_txt = txt
    for orig_url, avif_rel in mapping.items():
        pattern = re.escape(orig_url.split('?')[0]) + r'(?:\?[^\s"\']*)?'
        txt = re.sub(pattern, avif_rel, txt)
    if txt != orig_txt:
        bak = path + '.bak'
        print("Updating", path, "-> backup:", bak)
        open(bak, 'w', encoding='utf-8').write(orig_txt)
        open(path, 'w', encoding='utf-8').write(txt)
print("Replacements done.")
PY
  echo "Replacement pass complete. Inspect .bak files if needed."
fi

echo "All finished. AVIF files are under assets/images/all/<section>/"


  AVIF conversion failed for /workspaces/fun-quiz-2/assets/images/all/reading/orig/unnamed-2-99e09959.gif
Skipping existing: reading/image-4ba044ab.avif
Skipping existing: reading/image-a41bf3ae.avif
Done. Mapping: /workspaces/fun-quiz-2/assets/images/all/postimg-mapping-by-section-avif.csv
All finished. AVIF files are under assets/images/all/<section>/
     44 geography
     33 index
     27 animals
     22 colors
     19 math
     16 brain-teasers
     14 reading
      1 leaderboard