#!/bin/sh
# Announces newly-ingested BookOrbit books to a Discord webhook.
#
# Ported from grimmory-discord-notify.sh on 2026-08-22. Same poller pattern as
# romm-discord-notify — a bug fixed in one is
# usually worth checking in the other.
#
# This is the "it landed in the library" signal, deliberately NOT Shelfmark's
# download_complete: since the switch to BOOKS_OUTPUT_MODE=folder, a completed
# download only reaches the Book Dock. It still has to clear auto-finalize
# before it is a book, so only BookOrbit knows one actually arrived. Shelfmark
# also cannot produce a rich card at all — its NotificationContext holds only
# title/author/format/source and Apprise sends plain text.
#
# Two things got simpler versus the Grimmory version:
#   - No metadata refresh. Book Dock enriches on ingest, so books arrive with
#     real metadata and there is no announce-before-metadata race, no
#     REFRESH_METADATA_MANUAL task, and no rewriting of the EPUB on disk.
#   - The cover endpoint reports an honest Content-Type (Grimmory's claimed
#     application/json while returning image bytes). The magic-number sniff is
#     kept as a fallback because that bug silently disabled every cover once.
#
# Covers still 401 anonymously, so they cannot be linked by URL; the bytes are
# uploaded with the webhook as multipart and referenced as attachment://.
# Upside: ebook covers stay private rather than becoming publicly fetchable.
#
# First run seeds the high-water-mark and announces NOTHING.

set -eu

BOOKORBIT_URL="${BOOKORBIT_URL:-http://bookorbit:3000}"
BOOKORBIT_USER="${BOOKORBIT_USER:-}"
BOOKORBIT_PASS="${BOOKORBIT_PASS:-}"
PUBLIC_URL="${PUBLIC_URL:-https://ebooks.yourdomain.com}"
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"
POLL_INTERVAL="${POLL_INTERVAL:-300}"
STATE_FILE="${STATE_FILE:-/state/last_book_id}"
# Ebooks arrive one or two at a time, so the default is a rich per-book message.
# A library rescan could still add many at once; above this, post one plain
# summary embed (no covers — Discord allows at most 10 attachments per message).
BULK_THRESHOLD="${BULK_THRESHOLD:-8}"
WEBHOOK_USERNAME="${WEBHOOK_USERNAME:-BookOrbit}"
EMBED_COLOR="${EMBED_COLOR:-10181046}"
# How many of the most recent books to examine each tick. The high-water-mark
# does the real work; this only bounds the query.
PAGE_SIZE="${PAGE_SIZE:-100}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
die() { log "ERROR: $*"; exit 1; }

[ -n "$BOOKORBIT_USER" ] || die "BOOKORBIT_USER is required"
[ -n "$BOOKORBIT_PASS" ] || die "BOOKORBIT_PASS is required"
[ -n "$DISCORD_WEBHOOK" ] || die "DISCORD_WEBHOOK is required"

mkdir -p "$(dirname "$STATE_FILE")"
WORK=/tmp/bookorbit-notify
mkdir -p "$WORK"
TOKEN=""

login() {
  # ⚠️ BookOrbit throttles POST /auth/login hard (429 for minutes after a
  # handful in quick succession), so this is only ever called on a 401 — never
  # per tick, and never in a retry loop.
  if ! jq -n --arg u "$BOOKORBIT_USER" --arg p "$BOOKORBIT_PASS" \
         '{username:$u,password:$p}' \
       | curl -fsS --max-time 30 -H "Content-Type: application/json" \
              -X POST --data-binary @- "${BOOKORBIT_URL}/api/v1/auth/login" \
              > "$WORK/login.json"; then
    log "WARN: BookOrbit login failed"
    return 1
  fi
  TOKEN=$(jq -r '.accessToken // empty' "$WORK/login.json")
  [ -n "$TOKEN" ] || { log "WARN: login response had no accessToken"; return 1; }
  return 0
}

# GET $1 -> $2 ; re-authenticates once on 401.
api_get() {
  _path="$1"; _out="$2"
  [ -n "$TOKEN" ] || login || return 1
  _code=$(curl -sS -o "$_out" -w '%{http_code}' --max-time 60 \
            -H "Authorization: Bearer ${TOKEN}" "${BOOKORBIT_URL}${_path}")
  if [ "$_code" = "401" ]; then
    log "token rejected, re-authenticating"
    login || return 1
    _code=$(curl -sS -o "$_out" -w '%{http_code}' --max-time 60 \
              -H "Authorization: Bearer ${TOKEN}" "${BOOKORBIT_URL}${_path}")
  fi
  case "$_code" in
    2*) return 0 ;;
    *)  log "WARN: GET ${_path} returned HTTP ${_code}"; return 1 ;;
  esac
}

# POST $2 (a JSON string) to $1 -> $3 ; re-authenticates once on 401.
# Note the book listing is a POST, not a GET — see api_query below.
api_post() {
  _path="$1"; _body="$2"; _out="$3"
  [ -n "$TOKEN" ] || login || return 1
  _code=$(printf '%s' "$_body" | curl -sS -o "$_out" -w '%{http_code}' --max-time 60 \
            -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
            -X POST --data-binary @- "${BOOKORBIT_URL}${_path}")
  if [ "$_code" = "401" ]; then
    login || return 1
    _code=$(printf '%s' "$_body" | curl -sS -o "$_out" -w '%{http_code}' --max-time 60 \
              -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
              -X POST --data-binary @- "${BOOKORBIT_URL}${_path}")
  fi
  case "$_code" in
    2*) return 0 ;;
    *)  log "WARN: POST ${_path} returned HTTP ${_code}: $(head -c 200 "$_out")"; return 1 ;;
  esac
}

# The library listing. Unlike Grimmory's GET /api/v1/books (a bare array), this
# is POST /api/v1/books/query and returns {items,total,page,size}.
api_query() {
  api_post "/api/v1/books/query" \
    "$(jq -nc --argjson n "$PAGE_SIZE" \
        '{page:1,pageSize:$n,sortBy:"addedAt",sortDir:"desc"}')" \
    "$WORK/query.json"
}

post_discord() {
  # $1 = payload file, $2 = optional cover file, $3 = attachment filename,
  # $4 = mime type
  _payload="$1"; _cover="${2:-}"; _fn="${3:-cover.jpg}"; _mime="${4:-image/jpeg}"
  if [ -n "$_cover" ] && [ -s "$_cover" ]; then
    _code=$(curl -sS -o "$WORK/resp" -w '%{http_code}' --max-time 60 \
      -F "payload_json=<${_payload};type=application/json" \
      -F "files[0]=@${_cover};type=${_mime};filename=${_fn}" \
      "$DISCORD_WEBHOOK")
  else
    _code=$(curl -sS -o "$WORK/resp" -w '%{http_code}' --max-time 60 \
      -H "Content-Type: application/json" \
      -X POST --data-binary "@${_payload}" "$DISCORD_WEBHOOK")
  fi
  case "$_code" in
    2*) return 0 ;;
    429)
      _retry=$(jq -r '.retry_after // 5' "$WORK/resp" 2>/dev/null || echo 5)
      _retry=$(( $(printf '%.0f' "$_retry") + 1 ))
      log "WARN: Discord rate limited, sleeping ${_retry}s"
      sleep "$_retry"
      return 1
      ;;
    *)
      log "ERROR: Discord POST failed (HTTP ${_code}): $(head -c 300 "$WORK/resp")"
      return 1
      ;;
  esac
}

# Build the embed for one book. $1 = book detail JSON, $2 = attachment filename
# ("" when no cover could be attached).
#
# BookOrbit descriptions are HTML (Grimmory had none at all), so tags are
# stripped and the result truncated to keep the embed inside Discord's limits.
build_embed() {
  jq --arg pub "$PUBLIC_URL" \
     --arg user "$WEBHOOK_USERNAME" \
     --argjson color "$EMBED_COLOR" \
     --arg coverfile "$2" '
    def field(n; v): if (v // "") == "" then empty else {name: n, value: (v|tostring), inline: true} end;
    def detag: if . == null then null else
      gsub("<[^>]*>"; "") | gsub("&nbsp;"; " ") | gsub("&amp;"; "&")
      | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&#39;"; "\u0027") | gsub("&quot;"; "\"")
      | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ")
      end;
    (.files // []) as $files |
    ($files | map(select(.role == "primary")) | first // ($files | first)) as $f |
    {
      username: $user,
      embeds: [ ({
        title: (.title // "Untitled"),
        url: ($pub + "/book/" + (.id | tostring)),
        color: $color,
        description: (
          ((.authors // []) | map(if type == "object" then .name else . end)) as $a
          | ((if ($a | length) > 0 then "by " + ($a | join(", ")) else "" end)) as $by
          | ((.description | detag) // "") as $d
          | ($d | if length > 600 then .[0:600] + "…" else . end) as $syn
          | if $by == "" and $syn == "" then null
            elif $syn == "" then $by
            elif $by == "" then $syn
            else $by + "\n\n" + $syn end
        ),
        fields: [
          field("Series";
            (if (.seriesName // "") != "" then
               .seriesName + (if (.seriesIndex // null) != null then " #" + (.seriesIndex|tostring) else "" end)
             else null end)),
          field("Published"; (.publishedYear // (.publishedDate // null | if . then (.|tostring)[0:4] else null end))),
          field("Publisher"; .publisher),
          field("Pages"; .pageCount),
          field("Rating"; (.rating // null | if . then ((.*10|floor)/10|tostring) + " ★" else null end)),
          field("Format";
            (if ($f.format // "") != "" then
               ($f.format | ascii_upcase)
               + (if ($f.sizeBytes // null) != null then " · " + (($f.sizeBytes/1048576*10|floor)/10|tostring) + " MB" else "" end)
             else null end))
        ],
        image: (if $coverfile != "" then {url: ("attachment://" + $coverfile)} else null end),
        footer: { text: ("Added to " + (.libraryName // "the ebook library")) }
      } | with_entries(select(.value != null))) ]
    }' "$1"
}

announce_one() {
  # $1 = book id
  _id="$1"
  # The list record is thin; the detail record carries description, publisher
  # and libraryName, so always announce from the detail.
  if ! api_get "/api/v1/books/${_id}" "$WORK/book.json"; then
    log "  book ${_id}: detail fetch failed, skipping this tick"
    return 1
  fi

  _cover="$WORK/cover.bin"
  rm -f "$_cover"
  _fn=""; _mime=""
  if api_get "/api/v1/books/${_id}/cover" "$_cover"; then
    # BookOrbit sends a correct Content-Type, but sniff the magic number anyway
    # — trusting Grimmory's header was what silently disabled every cover on the
    # first deploy of the old feed. `od -An -tx1` emits space-separated bytes,
    # hence the tr.
    _magic=$(head -c 4 "$_cover" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    case "$_magic" in
      ffd8*)     _fn="cover.jpg"; _mime="image/jpeg" ;;
      89504e47*) _fn="cover.png"; _mime="image/png" ;;
      *)         log "  book ${_id}: cover was not JPEG/PNG (magic=${_magic:-empty}), posting without image" ;;
    esac
  else
    log "  book ${_id}: cover fetch failed, posting without image"
  fi

  build_embed "$WORK/book.json" "$_fn" > "$WORK/payload.json"
  if [ -n "$_fn" ]; then
    post_discord "$WORK/payload.json" "$_cover" "$_fn" "$_mime"
  else
    post_discord "$WORK/payload.json"
  fi
}

announce_bulk() {
  jq --arg pub "$PUBLIC_URL" --arg user "$WEBHOOK_USERNAME" --argjson color "$EMBED_COLOR" '
    (length) as $n
    | {
        username: $user,
        embeds: [{
          title: (($n | tostring) + " new books added"),
          url: ($pub + "/"),
          color: $color,
          description: (
            [ .[0:20][] | "• **" + (.title // "Untitled") + "**"
              + (((.authors // []) | map(if type == "object" then .name else . end)
                  | if length > 0 then " — " + join(", ") else "" end)) ]
            | join("\n")
          ) + (if $n > 20 then "\n• …and " + (($n - 20)|tostring) + " more" else "" end),
          footer: { text: "Added to the ebook library" }
        }]
      }' "$WORK/batch.json" > "$WORK/payload.json"
  post_discord "$WORK/payload.json"
}

log "bookorbit-discord-notify starting"
log "  BookOrbit: ${BOOKORBIT_URL}  (public ${PUBLIC_URL})"
log "  Interval: ${POLL_INTERVAL}s   bulk threshold: ${BULK_THRESHOLD}"

while :; do
  if [ -s "$STATE_FILE" ]; then last_id=$(cat "$STATE_FILE"); else last_id=""; fi

  if api_query; then
    if [ -z "$last_id" ]; then
      seed=$(jq '[.items[].id] | max // 0' "$WORK/query.json")
      echo "$seed" > "$STATE_FILE"
      log "Seeded high-water-mark at book id ${seed}; no notifications for existing library"
    else
      jq -c --argjson last "$last_id" '[ .items[] | select(.id > $last) ] | sort_by(.id)' \
        "$WORK/query.json" > "$WORK/batch.json"
      count=$(jq 'length' "$WORK/batch.json")

      if [ "$count" -gt 0 ]; then
        log "${count} new book(s) since id ${last_id}"
        highest="$last_id"
        if [ "$count" -gt "$BULK_THRESHOLD" ]; then
          if announce_bulk; then
            highest=$(jq '[.[].id] | max' "$WORK/batch.json")
          fi
        else
          # Advance the mark per book, so a failure mid-batch re-announces only
          # what did not get posted rather than the whole batch.
          for id in $(jq -r '.[].id' "$WORK/batch.json"); do
            if announce_one "$id"; then
              highest="$id"
            else
              log "  book ${id}: announce failed, will retry next tick"
              break
            fi
          done
        fi
        if [ "$highest" != "$last_id" ]; then
          echo "$highest" > "$STATE_FILE"
          log "high-water-mark now ${highest}"
        fi
      fi
    fi
  fi

  sleep "$POLL_INTERVAL"
done
