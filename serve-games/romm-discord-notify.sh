#!/bin/sh
# Announces newly-added RomM games to a Discord webhook.
#
# RomM has no webhooks or notification agents of its own (checked against
# docs.romm.app and the 5.x OpenAPI surface), so this polls GET /api/roms and
# diffs against a high-water-mark of the last announced rom id.
#
# Why id and not created_at: rom ids are autoincrement and monotonic, and
# comparing integers avoids the ISO-8601 fractional-second parsing that string
# comparison would need. created_at is stable across rescans (the April 2026
# import still carries its original timestamps), so the nightly QUICK rescan
# re-identifying existing files produces no notifications either way.
#
# First run seeds the high-water-mark and announces NOTHING — otherwise
# standing up this container would dump the whole library into the channel.

set -eu

ROMM_URL="${ROMM_URL:-http://romm:8080}"
ROMM_TOKEN="${ROMM_TOKEN:-}"
PUBLIC_URL="${PUBLIC_URL:-https://games.yourdomain.com}"
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"
POLL_INTERVAL="${POLL_INTERVAL:-300}"
STATE_FILE="${STATE_FILE:-/state/last_rom_id}"
PAGE_SIZE="${PAGE_SIZE:-100}"
MAX_PAGES="${MAX_PAGES:-10}"
# Above this many new roms in one poll, post a single grouped summary instead
# of one embed per game. A scan import can add hundreds at once (240 on
# 2026-08-16) and 24 consecutive messages is not a feed, it is a flood.
BULK_THRESHOLD="${BULK_THRESHOLD:-15}"
WEBHOOK_USERNAME="${WEBHOOK_USERNAME:-RomM}"
EMBED_COLOR="${EMBED_COLOR:-5793266}"

# Logs go to STDERR, never stdout: fetch_new's stdout IS the batch JSON
# (`fetch_new "$last_id" > "$WORK/batch.json"`), so a log line written to
# stdout lands inside that file and the next `jq` on it dies with
# "Invalid numeric literal at line 1, column 11" — the date prefix. That
# crash-looped this container for six days (2026-08-18 .. 08-24) once the
# high-water-mark fell far enough behind to trip the MAX_PAGES warning.
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[ -n "$ROMM_TOKEN" ] || die "ROMM_TOKEN is required (RomM client token, rmm_...)"
[ -n "$DISCORD_WEBHOOK" ] || die "DISCORD_WEBHOOK is required"

mkdir -p "$(dirname "$STATE_FILE")"

WORK=/tmp/romm-notify
mkdir -p "$WORK"

api() {
  curl -fsS --max-time 30 \
    -H "Authorization: Bearer ${ROMM_TOKEN}" \
    -H "Accept: application/json" \
    "$@"
}

# Emits a JSON array of roms with id > $1, oldest first.
fetch_new() {
  _last="$1"
  _offset=0
  _page=0
  : > "$WORK/new.jsonl"
  while [ "$_page" -lt "$MAX_PAGES" ]; do
    if ! api "${ROMM_URL}/api/roms?order_by=id&order_dir=desc&limit=${PAGE_SIZE}&offset=${_offset}" \
         > "$WORK/page.json"; then
      log "WARN: /api/roms request failed (page ${_page}), will retry next poll"
      return 1
    fi
    _count=$(jq '.items | length' "$WORK/page.json")
    [ "$_count" -eq 0 ] && break
    jq -c --argjson last "$_last" '.items[] | select(.id > $last)' "$WORK/page.json" \
      >> "$WORK/new.jsonl"
    _min=$(jq '[.items[].id] | min' "$WORK/page.json")
    # Page contained something we have already announced -> nothing older is new.
    [ "$_min" -le "$_last" ] && break
    _offset=$((_offset + PAGE_SIZE))
    _page=$((_page + 1))
  done
  if [ "$_page" -ge "$MAX_PAGES" ]; then
    log "WARN: hit MAX_PAGES=${MAX_PAGES}; some older additions may be skipped"
  fi
  jq -s 'sort_by(.id)' "$WORK/new.jsonl"
}

post_discord() {
  # stdin: a complete Discord webhook JSON payload
  _code=$(curl -sS -o "$WORK/resp" -w '%{http_code}' --max-time 30 \
    -H "Content-Type: application/json" \
    -X POST --data-binary @- "$DISCORD_WEBHOOK")
  case "$_code" in
    2*) return 0 ;;
    429)
      _retry=$(jq -r '.retry_after // 5' "$WORK/resp" 2>/dev/null || echo 5)
      # retry_after is fractional seconds; round up and add a margin.
      _retry=$(( $(printf '%.0f' "$_retry") + 1 ))
      log "WARN: Discord rate limited, sleeping ${_retry}s and retrying once"
      sleep "$_retry"
      _code=$(curl -sS -o "$WORK/resp" -w '%{http_code}' --max-time 30 \
        -H "Content-Type: application/json" \
        -X POST --data-binary @- "$DISCORD_WEBHOOK" < "$WORK/payload.json")
      case "$_code" in 2*) return 0 ;; esac
      log "ERROR: Discord POST failed after retry (HTTP ${_code}): $(head -c 300 "$WORK/resp")"
      return 1
      ;;
    *)
      log "ERROR: Discord POST failed (HTTP ${_code}): $(head -c 300 "$WORK/resp")"
      return 1
      ;;
  esac
}

# Individual embeds, max 10 per Discord message.
announce_each() {
  _total=$(jq 'length' "$WORK/batch.json")
  _i=0
  while [ "$_i" -lt "$_total" ]; do
    jq --arg pub "$PUBLIC_URL" \
       --arg user "$WEBHOOK_USERNAME" \
       --argjson color "$EMBED_COLOR" \
       --argjson from "$_i" \
       --argjson big "$( [ "$_total" -le 3 ] && echo true || echo false )" '
      # The API returns path_cover_* already rooted at /assets/romm/resources/
      # and suffixed with a "?ts=<mtime>" cache-buster that contains a literal
      # space — which Discord will not accept in an embed URL. Strip the query;
      # nginx still serves the file, just with must-revalidate instead of
      # immutable caching, which is irrelevant for a one-shot embed fetch.
      def cover:
        ( (.path_cover_large // "") as $l | (.path_cover_small // "") as $s
          | if $l != "" then $l elif $s != "" then $s else null end )
        | if . == null or . == "" then null
          else $pub + (sub("\\?.*$"; "")) end;
      {
        username: $user,
        embeds: [ .[$from : $from + 10][] | {
          title: (.name // .fs_name_no_ext // .fs_name),
          url: ($pub + "/rom/" + (.id | tostring)),
          color: $color,
          description: (
            (.summary // "")
            | if length > 300 then .[0:297] + "..." else . end
            | if . == "" then null else . end
          ),
          footer: { text: (.platform_display_name // .platform_custom_name // .platform_slug // "Unknown platform") },
          image:     (if $big     then (cover | if . then {url: .} else null end) else null end),
          thumbnail: (if $big|not then (cover | if . then {url: .} else null end) else null end)
        } | with_entries(select(.value != null)) ]
      }' "$WORK/batch.json" > "$WORK/payload.json"
    post_discord < "$WORK/payload.json" || return 1
    _i=$((_i + 10))
    if [ "$_i" -lt "$_total" ]; then sleep 1; fi
  done
  return 0
}

# One grouped summary embed for large scan imports.
announce_bulk() {
  jq --arg pub "$PUBLIC_URL" \
     --arg user "$WEBHOOK_USERNAME" \
     --argjson color "$EMBED_COLOR" '
    (length) as $n
    | group_by(.platform_display_name // .platform_custom_name // .platform_slug // "Unknown")
    | map({
        name: ((.[0].platform_display_name // .[0].platform_custom_name // .[0].platform_slug // "Unknown")
               + " (" + (length | tostring) + ")"),
        value: (
          ( .[0:12] | map("• " + (.name // .fs_name_no_ext // .fs_name)) | join("\n") )
          + (if length > 12 then "\n• …and " + ((length - 12) | tostring) + " more" else "" end)
        ),
        inline: true
      })
    | {
        username: $user,
        embeds: [{
          title: (($n | tostring) + " new games added"),
          url: ($pub + "/"),
          color: $color,
          fields: .[0:25],
          footer: { text: "RomM library scan" }
        }]
      }' "$WORK/batch.json" > "$WORK/payload.json"
  post_discord < "$WORK/payload.json"
}

log "romm-discord-notify starting"
log "  RomM:     ${ROMM_URL}  (public ${PUBLIC_URL})"
log "  Interval: ${POLL_INTERVAL}s   bulk threshold: ${BULK_THRESHOLD}"

while :; do
  if [ -s "$STATE_FILE" ]; then
    last_id=$(cat "$STATE_FILE")
  else
    last_id=""
  fi

  if [ -z "$last_id" ]; then
    # Seed: record the newest id, announce nothing.
    if api "${ROMM_URL}/api/roms?order_by=id&order_dir=desc&limit=1" > "$WORK/seed.json"; then
      seed=$(jq '.items[0].id // 0' "$WORK/seed.json")
      echo "$seed" > "$STATE_FILE"
      log "Seeded high-water-mark at rom id ${seed}; no notifications for existing library"
    else
      log "WARN: seed request failed, retrying next poll"
    fi
    sleep "$POLL_INTERVAL"
    continue
  fi

  if fetch_new "$last_id" > "$WORK/batch.json"; then
    count=$(jq 'length' "$WORK/batch.json")
    if [ "$count" -gt 0 ]; then
      newest=$(jq '[.[].id] | max' "$WORK/batch.json")
      log "${count} new rom(s) since id ${last_id} (newest ${newest})"
      if [ "$count" -gt "$BULK_THRESHOLD" ]; then
        ok=0; announce_bulk && ok=1
      else
        ok=0; announce_each && ok=1
      fi
      if [ "$ok" -eq 1 ]; then
        echo "$newest" > "$STATE_FILE"
        log "Announced ${count} rom(s); high-water-mark now ${newest}"
      else
        log "Announcement failed; leaving high-water-mark at ${last_id} to retry next poll"
      fi
    fi
  fi

  sleep "$POLL_INTERVAL"
done
