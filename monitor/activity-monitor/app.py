#!/usr/bin/env python3
"""activity-monitor — "is anyone using the system right now?"

Closes the visibility gap left by the two stacks that do not go through
Plex/Tautulli: ebooks (BookOrbit) and retro games (RomM). The point is the
PRE-CHANGE GATE — before a reboot, a router upgrade, or anything disruptive,
one call answers whether a human is mid-book or mid-game.

Two sources, deliberately different, because the apps are different:

  RomM      — first-party. GET /api/activity returns "every currently active
              play session across all users", backed by a 90s Redis TTL that
              browser (Socket.IO activity:heartbeat) and device (muOS/Android)
              clients refresh. Authoritative; we pass it through as-is and do
              NOT apply our own window to it.

  BookOrbit — no such API exists. Checked 2026-08-24 against 2.6.0:
              dashboard/widgets/currently-reading is scoped to the CALLING
              user, account-activity is login timestamps only, and statistics
              is library shape. And its JWT lives 15 minutes, so homepage's
              customapi (static auth only) could not call it even if a route
              existed. So we read Postgres directly.

              The live signal is reading_progress.updated_at, NOT
              reading_sessions. Sessions are flush/terminal records written on
              unload via sendBeacon — measured 2026-08-24, liu.y7's progress
              had moved at 08-23 23:29 while their newest session row still
              ended 08-22 11:52. A session row can therefore lag a live reader
              by a day; progress cannot.

Reads only. Holds a SELECT-only postgres role and a roms.user.read token, so
the worst it can do is answer this question.
"""

import json
import os
import ssl
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pg8000.native

LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8788"))
REFRESH_SECONDS = int(os.environ.get("REFRESH_SECONDS", "30"))

# How recently reading_progress must have moved for a reader to count as
# "active". A page turn is the only thing that bumps it, so this must tolerate
# a slow reader sitting on one page -- 15 minutes is deliberately generous.
# RomM is NOT subject to this; its own 90s TTL already defines "active".
READER_WINDOW_MIN = int(os.environ.get("READER_WINDOW_MIN", "15"))

PG_HOST = os.environ.get("BOOKORBIT_DB_HOST", "bookorbit-postgres")
PG_PORT = int(os.environ.get("BOOKORBIT_DB_PORT", "5432"))
PG_NAME = os.environ.get("BOOKORBIT_DB_NAME", "bookorbit")
PG_USER = os.environ.get("BOOKORBIT_DB_USER", "svc_activity")
PG_PASS = os.environ.get("BOOKORBIT_DB_PASSWORD", "")

ROMM_URL = os.environ.get("ROMM_URL", "http://server.mylocal:8095").rstrip("/")
ROMM_TOKEN = os.environ.get("ROMM_TOKEN", "")

HTTP_TIMEOUT = int(os.environ.get("HTTP_TIMEOUT", "10"))

# book_metadata.title is the display title; books itself has no title column
# (only primary_author_sort_name). Verified against the live schema.
READERS_SQL = """
SELECT u.username,
       COALESCE(m.title, 'Unknown book')  AS book,
       p.percentage                       AS pct,
       EXTRACT(EPOCH FROM (now() - p.updated_at)) / 60.0 AS idle_min
  FROM reading_progress p
  JOIN users u        ON u.id = p.user_id
  LEFT JOIN book_files f    ON f.id = p.book_file_id
  LEFT JOIN book_metadata m ON m.book_id = f.book_id
 WHERE p.updated_at > now() - make_interval(mins => :win)
 ORDER BY p.updated_at DESC
"""

# Reported even when nobody is active, so the gate can distinguish "quiet for
# weeks" from "someone put the book down four minutes ago". Seconds, because
# homepage's `format: duration` takes seconds (same as qBittorrent's eta) and
# renders them human-readably -- a raw minute count is useless at 20 days.
LAST_READ_SQL = """
SELECT EXTRACT(EPOCH FROM (now() - MAX(p.updated_at)))
  FROM reading_progress p
"""


def _now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def fetch_readers():
    """BookOrbit readers active within READER_WINDOW_MIN. Returns (list, last_read_min)."""
    conn = pg8000.native.Connection(
        user=PG_USER,
        password=PG_PASS,
        host=PG_HOST,
        port=PG_PORT,
        database=PG_NAME,
        timeout=HTTP_TIMEOUT,
    )
    try:
        rows = conn.run(READERS_SQL, win=READER_WINDOW_MIN)
        readers = [
            {
                "user": r[0],
                "book": r[1],
                "pct": round(float(r[2]), 1) if r[2] is not None else None,
                "idle_min": round(float(r[3]), 1),
            }
            for r in rows
        ]
        last = conn.run(LAST_READ_SQL)
        last_read_sec = (
            int(float(last[0][0]))
            if last and last[0][0] is not None
            else None
        )
        return readers, last_read_sec
    finally:
        try:
            conn.close()
        except Exception:
            pass


def fetch_players():
    """RomM's own currently-active play sessions. Pass-through, no extra filtering."""
    req = urllib.request.Request(
        f"{ROMM_URL}/api/activity",
        headers={
            "Authorization": f"Bearer {ROMM_TOKEN}",
            "Accept": "application/json",
        },
    )
    ctx = ssl.create_default_context() if ROMM_URL.startswith("https") else None
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT, context=ctx) as resp:
        entries = json.loads(resp.read().decode())

    players = []
    for e in entries:
        started = e.get("started_at")
        playing_min = None
        if started:
            try:
                t = datetime.fromisoformat(started.replace("Z", "+00:00"))
                if t.tzinfo is None:
                    t = t.replace(tzinfo=timezone.utc)
                playing_min = round(
                    (datetime.now(timezone.utc) - t).total_seconds() / 60.0, 1
                )
            except ValueError:
                pass
        players.append(
            {
                "user": e.get("username"),
                "game": e.get("rom_name"),
                "platform": e.get("platform_name") or e.get("platform_slug"),
                "device": e.get("device_type"),
                "playing_min": playing_min,
            }
        )
    return players


class State:
    """Last good snapshot + whatever went wrong producing it.

    A source that fails is reported in `errors` and its list is left EMPTY --
    never silently omitted. An empty list with no error means "checked, nobody
    there"; an empty list WITH an error means "could not tell". The gate must
    be able to distinguish those, because treating "unknown" as "clear" is how
    you reboot on top of someone.
    """

    def __init__(self):
        self.lock = threading.Lock()
        self.payload = {
            "active": 0,
            "reader_count": 0,
            "player_count": 0,
            "readers": [],
            "players": [],
            "last_read_min": None,
            "last_read_seconds": None,
            "window_min": READER_WINDOW_MIN,
            "checked_at": None,
            "status": "degraded",
            "stale": True,
            "errors": ["starting up"],
        }

    def refresh(self):
        errors = []
        readers, last_read_sec = [], None
        players = []

        try:
            readers, last_read_sec = fetch_readers()
        except Exception as exc:  # noqa: BLE001 - surface anything as an error string
            errors.append(f"bookorbit: {type(exc).__name__}: {exc}")

        try:
            players = fetch_players()
        except urllib.error.HTTPError as exc:
            errors.append(f"romm: HTTP {exc.code}")
        except Exception as exc:  # noqa: BLE001
            errors.append(f"romm: {type(exc).__name__}: {exc}")

        payload = {
            "active": len(readers) + len(players),
            "reader_count": len(readers),
            "player_count": len(players),
            "readers": readers,
            "players": players,
            "last_read_min": round(last_read_sec / 60.0, 1) if last_read_sec is not None else None,
            "last_read_seconds": last_read_sec,
            "window_min": READER_WINDOW_MIN,
            "checked_at": _now_iso(),
            # `status` exists so the DASHBOARD can show staleness. The JSON has
            # always carried `stale`, but a homepage tile rendering 0/0 looks
            # identical whether nobody is here or both sources are unreachable
            # -- which launders "could not tell" back into a confident zero,
            # the exact trap the payload is shaped to avoid.
            "status": "degraded" if errors else "ok",
            "stale": bool(errors),
            "errors": errors,
        }
        with self.lock:
            self.payload = payload
        return payload

    def get(self):
        with self.lock:
            return dict(self.payload)


STATE = State()


def poller():
    while True:
        try:
            p = STATE.refresh()
            if p["errors"]:
                print(f"{_now_iso()} refresh errors: {p['errors']}")
        except Exception as exc:  # noqa: BLE001 - the loop must never die
            print(f"{_now_iso()} poller crashed: {type(exc).__name__}: {exc}")
        time.sleep(REFRESH_SECONDS)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        raw = json.dumps(body, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path in ("/", "/activity.json", "/activity"):
            self._send(200, STATE.get())
        elif path == "/healthz":
            p = STATE.get()
            # Healthy means "the poller is running and produced a snapshot".
            # A source being down is reported in the payload, not by failing
            # the healthcheck -- otherwise a RomM restart would take this
            # container down with it and destroy the very visibility it exists
            # to provide.
            ok = p["checked_at"] is not None
            self._send(200 if ok else 503, {"ok": ok, "checked_at": p["checked_at"]})
        else:
            self._send(404, {"error": "not found", "path": path})

    def log_message(self, fmt, *args):
        return  # quiet: one line per poll is plenty


def main():
    print(f"{_now_iso()} activity-monitor starting")
    print(f"  BookOrbit DB: {PG_USER}@{PG_HOST}:{PG_PORT}/{PG_NAME}")
    print(f"  RomM:         {ROMM_URL}")
    print(f"  reader window {READER_WINDOW_MIN}m, refresh {REFRESH_SECONDS}s")

    STATE.refresh()
    threading.Thread(target=poller, daemon=True).start()

    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
