#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./convert_note_to_markdown.sh <export_dir> [output_root]

Example:
  ./convert_note_to_markdown.sh ./note_exports_test/rochefort10_20260422-142216 .

Output folders:
  - 201
  - PTA
  - others
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required." >&2
  exit 1
fi
if ! command -v perl >/dev/null 2>&1; then
  echo "Error: perl is required." >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required." >&2
  exit 1
fi

SRC_DIR="${1%/}"
OUT_ROOT="${2:-.}"
NOTES_DIR="${SRC_DIR}/notes"
IMAGES_ROOT="${OUT_ROOT}/_images"

if [[ ! -d "$NOTES_DIR" ]]; then
  echo "Error: notes directory not found: $NOTES_DIR" >&2
  exit 1
fi

mkdir -p "$OUT_ROOT/201" "$OUT_ROOT/PTA" "$OUT_ROOT/others" "$IMAGES_ROOT"

sanitize_filename() {
  local s="$1"
  s="$(printf '%s' "$s" | tr '[:space:]' '_' | tr -cd '[:alnum:]_.-')"
  [[ -z "$s" ]] && s="untitled"
  printf '%s' "$s"
}

html_to_markdown() {
  PERL_BADLANG=0 perl -0777 -pe '
    s/\r//g;
    s/<br\s*\/?\s*>/\n/gi;
    s@<h([1-6])\b[^>]*>(.*?)</h\1>@"\n".("#" x $1)." ".$2."\n\n"@gise;
    s@<img\b[^>]*alt=["\x27]([^"\x27]*)["\x27][^>]*src=["\x27]([^"\x27]+)["\x27][^>]*>@"![".$1."](".$2.")"@gise;
    s@<img\b[^>]*src=["\x27]([^"\x27]+)["\x27][^>]*alt=["\x27]([^"\x27]*)["\x27][^>]*>@"![".$2."](".$1.")"@gise;
    s@<img\b[^>]*src=["\x27]([^"\x27]+)["\x27][^>]*>@"![](".$1.")"@gise;
    s@<li\b[^>]*>(.*?)</li>@"- ".$1."\n"@gise;
    s@</?(ul|ol)\b[^>]*>@"\n"@gise;
    s@<a\b[^>]*href=["\x27]([^"\x27]+)["\x27][^>]*>(.*?)</a>@"[".$2."](".$1.")"@gise;
    s@</p>@"\n\n"@gise;
    s@<p\b[^>]*>@@gise;
    s/<[^>]+>//g;
    s/&nbsp;/ /g;
    s/&amp;/&/g;
    s/&lt;/</g;
    s/&gt;/>/g;
    s/&quot;/"/g;
    s/&#39;/'"'"'/g;
    s/\n{3,}/\n\n/g;
    s/^\s+|\s+$//g;
  '
}

extract_ext() {
  local url="$1"
  local path file ext
  path="${url%%\?*}"
  file="${path##*/}"
  ext="${file##*.}"
  if [[ "$ext" == "$file" ]]; then
    ext="jpg"
  fi
  ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
  if ! printf '%s' "$ext" | rg -q '^[a-z0-9]{2,5}$'; then
    ext="jpg"
  fi
  printf '%s' "$ext"
}

download_file() {
  local url="$1"
  local dest="$2"
  if curl -fsSL --retry 2 --retry-delay 1 "$url" -o "$dest"; then
    return 0
  fi
  return 1
}

processed=0
downloaded_images=0
for json in "$NOTES_DIR"/*.json; do
  [[ -f "$json" ]] || continue

  base="${json%.json}"
  html="${base}.html"
  [[ -f "$html" ]] || continue

  title="$(jq -r '.name // "untitled"' "$json")"
  key="$(jq -r '.key // empty' "$json")"
  note_url="$(jq -r '.noteUrl // empty' "$json")"
  published_at="$(jq -r '.publishAt // .createdAt // empty' "$json")"

  category="others"
  if printf '%s' "$title" | rg -qi 'pta'; then
    category="PTA"
  elif printf '%s' "$title" | rg -q '201'; then
    category="201"
  fi

  date_prefix="nodate"
  if [[ -n "$published_at" ]]; then
    date_prefix="$(printf '%s' "$published_at" | cut -c1-10 | tr -d '-')"
  fi

  safe_title="$(sanitize_filename "$title")"
  out_file="$OUT_ROOT/$category/${date_prefix}_${safe_title}_${key}.md"
  image_dir="$IMAGES_ROOT/$key"
  mkdir -p "$image_dir"

  eyecatch_url="$(jq -r '
    if (.eyecatch | type) == "string" then .eyecatch
    elif (.eyecatch | type) == "object" then (.eyecatch.original // .eyecatch.url // .eyecatch.path // empty)
    else empty
    end
  ' "$json")"
  eyecatch_md=""
  if [[ -n "$eyecatch_url" ]]; then
    eyecatch_ext="$(extract_ext "$eyecatch_url")"
    eyecatch_file="$image_dir/eyecatch.$eyecatch_ext"
    if download_file "$eyecatch_url" "$eyecatch_file"; then
      eyecatch_md="![eyecatch](../_images/${key}/eyecatch.${eyecatch_ext})"
      downloaded_images=$((downloaded_images + 1))
    fi
  fi

  body_html="$(cat "$html")"
  urls_tmp="$(mktemp)"
  pairs_tmp="$(mktemp)"

  printf '%s' "$body_html" | PERL_BADLANG=0 perl -nE 'while (/<img\b[^>]*\bsrc=["\x27]([^"\x27]+)["\x27][^>]*>/gi) { say $1 }' | awk 'NF && !seen[$0]++' > "$urls_tmp"

  img_index=1
  while IFS= read -r img_url; do
    [[ -n "$img_url" ]] || continue
    img_ext="$(extract_ext "$img_url")"
    img_name="$(printf 'body_%03d.%s' "$img_index" "$img_ext")"
    img_file="$image_dir/$img_name"
    if download_file "$img_url" "$img_file"; then
      token="__NOTE_IMG_${img_index}__"
      body_html="${body_html//$img_url/$token}"
      printf '%s\t%s\n' "$token" "../_images/${key}/${img_name}" >> "$pairs_tmp"
      downloaded_images=$((downloaded_images + 1))
      img_index=$((img_index + 1))
    fi
  done < "$urls_tmp"

  body_md="$(printf '%s' "$body_html" | html_to_markdown)"
  while IFS=$'\t' read -r token rel; do
    [[ -n "$token" ]] || continue
    body_md="${body_md//$token/$rel}"
  done < "$pairs_tmp"

  rm -f "$urls_tmp" "$pairs_tmp"

  {
    printf '# %s\n\n' "$title"
    if [[ -n "$note_url" ]]; then
      printf -- '- URL: %s\n' "$note_url"
    fi
    if [[ -n "$published_at" ]]; then
      printf -- '- Date: %s\n' "$published_at"
    fi
    if [[ -n "$key" ]]; then
      printf -- '- Key: %s\n' "$key"
    fi
    printf '\n'
    if [[ -n "$eyecatch_md" ]]; then
      printf '%s\n\n' "$eyecatch_md"
    fi
    printf '%s\n' "$body_md"
    printf '\n'
  } > "$out_file"

  processed=$((processed + 1))
done

echo "Converted: $processed files"
echo "Downloaded images: $downloaded_images"
echo "Output: $OUT_ROOT/{201,PTA,others}"
