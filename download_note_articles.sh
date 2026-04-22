#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./download_note_articles.sh <note_urlname> [output_dir]

Examples:
  ./download_note_articles.sh rochefort10
  ./download_note_articles.sh rochefort10 ./exports

What this script does:
  - Fetches all public notes for the given note.com account
  - Saves per-note metadata as JSON
  - Saves per-note body as HTML
  - Creates an index file for Git management

Requirements:
  - curl
  - jq
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

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required." >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required." >&2
  exit 1
fi

URLNAME="$1"
BASE_OUT="${2:-./note_exports}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${BASE_OUT%/}/${URLNAME}_${TS}"
NOTES_DIR="${OUT_DIR}/notes"
TMP_DIR="${OUT_DIR}/.tmp"
INDEX_FILE="${OUT_DIR}/index.jsonl"

mkdir -p "$NOTES_DIR" "$TMP_DIR"

api_get() {
  local url="$1"
  local out="$2"
  local code
  code=$(curl -sS -L \
    -H 'Accept: application/json' \
    -H 'User-Agent: note-exporter/1.0' \
    -w '%{http_code}' \
    "$url" \
    -o "$out")

  if [[ "$code" != "200" ]]; then
    echo "Error: request failed ($code): $url" >&2
    return 1
  fi
}

sanitize_filename() {
  local s="$1"
  s="$(printf '%s' "$s" | tr '[:space:]' '_' | tr -cd '[:alnum:]_.-')"
  s="${s#__}"
  s="${s%%__}"
  if [[ -z "$s" ]]; then
    s="untitled"
  fi
  printf '%s' "$s"
}

creator_json="${TMP_DIR}/creator.json"
api_get "https://note.com/api/v2/creators/${URLNAME}" "$creator_json"

if [[ "$(jq -r '.data.urlname // empty' "$creator_json")" != "$URLNAME" ]]; then
  echo "Error: creator not found or unexpected response for: ${URLNAME}" >&2
  exit 1
fi

nickname="$(jq -r '.data.nickname // ""' "$creator_json")"
total_count="$(jq -r '.data.noteCount // 0' "$creator_json")"

cat > "${OUT_DIR}/creator.json" <<EOF
$(jq '.' "$creator_json")
EOF

echo "Export target: ${URLNAME} (${nickname})"
echo "Expected public notes: ${total_count}"

: > "$INDEX_FILE"

page=1
while :; do
  page_json="${TMP_DIR}/page_${page}.json"
  api_get "https://note.com/api/v2/creators/${URLNAME}/contents?kind=note&page=${page}" "$page_json"

  is_last="$(jq -r '.data.isLastPage' "$page_json")"
  if [[ -z "$is_last" || "$is_last" == "null" ]]; then
    is_last="true"
  fi
  page_items="$(jq -r '.data.contents | length' "$page_json")"
  echo "Page ${page}: ${page_items} items"

  jq -c '.data.contents[]?' "$page_json" >> "$INDEX_FILE"

  if [[ "$is_last" == "true" ]]; then
    break
  fi
  page=$((page + 1))
done

# Remove duplicated keys if any
sort -u "$INDEX_FILE" > "${INDEX_FILE}.uniq"
mv "${INDEX_FILE}.uniq" "$INDEX_FILE"

exported=0
failed=0

while IFS= read -r item; do
  key="$(jq -r '.key // empty' <<<"$item")"
  if [[ -z "$key" ]]; then
    continue
  fi

  detail_json="${TMP_DIR}/note_${key}.json"
  if ! api_get "https://note.com/api/v3/notes/${key}" "$detail_json"; then
    echo "WARN: skip key=${key} (detail fetch failed)" >&2
    failed=$((failed + 1))
    continue
  fi

  title="$(jq -r '.data.name // "untitled"' "$detail_json")"
  created_at="$(jq -r '.data.createdAt // ""' "$detail_json")"
  updated_at="$(jq -r '.data.publishAt // .data.createdAt // ""' "$detail_json")"

  date_prefix=""
  if [[ -n "$updated_at" ]]; then
    date_prefix="$(printf '%s' "$updated_at" | cut -c1-10 | tr -d '-')"
  else
    date_prefix="nodate"
  fi

  safe_title="$(sanitize_filename "$title")"
  base_name="${date_prefix}_${safe_title}_${key}"

  jq '{
    id: .data.id,
    key: .data.key,
    name: .data.name,
    status: .data.status,
    type: .data.type,
    slug: .data.slug,
    noteUrl: .data.noteUrl,
    publishAt: .data.publishAt,
    createdAt: .data.createdAt,
    eyecatch: .data.eyecatch,
    user: .data.user,
    likeCount: .data.likeCount,
    commentCount: .data.commentCount,
    price: .data.price,
    canReadNote: .data.can_read_note,
    tags: .data.hashtagNotes
  }' "$detail_json" > "${NOTES_DIR}/${base_name}.json"

  jq -r '.data.body // ""' "$detail_json" > "${NOTES_DIR}/${base_name}.html"

  exported=$((exported + 1))
  sleep 0.2
done < "$INDEX_FILE"

# Save a lightweight manifest for diffs in Git.
jq -s 'map({key, name, noteUrl, publishAt, createdAt, status}) | sort_by(.publishAt // .createdAt // "")' "$NOTES_DIR"/*.json > "${OUT_DIR}/manifest.json" || true

cat <<EOF

Done.
Output directory: ${OUT_DIR}
Exported notes : ${exported}
Failed notes   : ${failed}

Suggested next steps:
  cd "${OUT_DIR}"
  git init
  git add .
  git commit -m "Export note.com articles (${URLNAME})"
EOF
