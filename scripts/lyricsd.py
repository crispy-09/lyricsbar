#!/usr/bin/python3
"""Touch Bar synced lyrics daemon.
Polls Spotify / Apple Music, fetches synced lyrics from lrclib.net,
and writes the current line to ~/.touchbar-lyrics/current.txt (read by MTMR)."""
import datetime, json, os, re, subprocess, threading, time, urllib.parse, urllib.request, hashlib

HOME = os.path.expanduser("~/.touchbar-lyrics")
CACHE = os.path.join(HOME, "cache")
OUT = os.path.join(HOME, "current.txt")
CONFIG = os.path.join(HOME, "config.json")
_cfg = {"t": 0, "mtime": None, "data": {}}

def setting(key, default):
    """Read a value from config.json (written by LyricsBar's Settings window), re-checked every 2s."""
    now = time.time()
    if now - _cfg["t"] > 2:
        _cfg["t"] = now
        try:
            m = os.path.getmtime(CONFIG)
            if m != _cfg["mtime"]:
                with open(CONFIG) as f:
                    _cfg["data"], _cfg["mtime"] = json.load(f), m
        except Exception:
            pass
    return _cfg["data"].get(key, default)
MAXLEN = 90
os.umask(0o077)                      # listening history / lyrics cache: private to this user
os.makedirs(CACHE, mode=0o700, exist_ok=True)
os.chmod(HOME, 0o700)

SCRIPT = r'''
set r to ""
if application "Spotify" is running then
  tell application "Spotify"
    if player state is playing then
      set t to current track
      set r to "playing" & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & ((duration of t) / 1000) & tab & (player position)
    end if
  end tell
end if
if r is "" and application "Music" is running then
  tell application "Music"
    if player state is playing then
      set t to current track
      set r to "playing" & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & (duration of t) & tab & (player position)
    end if
  end tell
end if
return r
'''

def player():
    try:
        out = subprocess.run(["osascript", "-e", SCRIPT], capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return None
    parts = out.split("\t")
    if len(parts) != 6 or parts[0] != "playing":
        return None
    num = lambda s: float(s.replace(",", "."))
    try:
        return dict(track=parts[1], artist=parts[2], album=parts[3], duration=num(parts[4]), position=num(parts[5]))
    except ValueError:
        return None

def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "touchbar-lyrics/1.0"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())

def parse_lrc(text):
    lines = []
    for raw in (text or "").splitlines():
        stamps = re.findall(r"\[(\d+):(\d+(?:\.\d+)?)\]", raw)
        words = re.sub(r"\[[^\]]*\]", "", raw).strip()
        for m, s in stamps:
            lines.append((int(m) * 60 + float(s), words))
    return sorted(lines)

def lyrics_for(p):
    key = hashlib.md5(f"{p['artist']}|{p['track']}".lower().encode()).hexdigest()
    path = os.path.join(CACHE, key + ".json")
    if os.path.exists(path):
        with open(path) as f:
            return [tuple(x) for x in json.load(f)]
    synced = None
    try:
        q = urllib.parse.urlencode(dict(artist_name=p["artist"], track_name=p["track"],
                                        album_name=p["album"], duration=round(p["duration"])))
        synced = fetch("https://lrclib.net/api/get?" + q).get("syncedLyrics")
    except Exception:
        pass
    if not synced:
        try:
            q = urllib.parse.urlencode(dict(artist_name=p["artist"], track_name=p["track"]))
            for r in fetch("https://lrclib.net/api/search?" + q):
                if r.get("syncedLyrics") and abs((r.get("duration") or 0) - p["duration"]) < 5:
                    synced = r["syncedLyrics"]; break
        except Exception:
            return None  # network error: don't cache, retry next song change
    lines = parse_lrc(synced)
    with open(path, "w") as f:
        json.dump(lines, f)
    return lines

def write(text):
    if len(text) > MAXLEN:
        text = text[:MAXLEN - 1] + "…"
    tmp = OUT + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, OUT)

import shutil
# Homebrew lives in /opt/homebrew on Apple silicon and /usr/local on Intel (most Touch Bar Macs)
MEDIA_CONTROL = next((p for p in ("/opt/homebrew/bin/media-control", "/usr/local/bin/media-control")
                      if os.path.exists(p)), shutil.which("media-control") or "media-control")
_np = {"state": None, "anchor": 0.0}
_lock = threading.Lock()

def _parse_ts(ts):
    try:
        return datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc).timestamp()
    except Exception:
        return None

STATE = os.path.join(HOME, "state.json")
ART = os.path.join(HOME, "artwork.jpg")

def _publish(p, last_art):
    """Write playback state + artwork for the Touch Bar app."""
    import base64
    info = {"playing": bool(p.get("playing")), "title": p.get("title", ""), "artist": p.get("artist", ""), "bundle": p.get("bundleIdentifier", "")}
    art_key = (info["title"], info["artist"])
    if art_key != last_art and not p.get("artworkData"):
        if os.path.exists(ART): os.remove(ART)   # new track, art not loaded yet
        last_art = None                          # whatever plays next (even the same song) must rewrite it
    elif p.get("artworkData") and (art_key != last_art or not os.path.exists(ART)):
        try:
            with open(ART + ".tmp", "wb") as f:
                f.write(base64.b64decode(p["artworkData"]))
            os.replace(ART + ".tmp", ART)
            last_art = art_key                   # only mark done once art is written
        except Exception:
            pass
    now, ts = time.time(), _parse_ts(p.get("timestamp", ""))
    info["elapsed"] = float(p.get("elapsedTime") or 0)
    info["anchor"] = now if ts is None or now - ts < 1.5 else ts + 0.5
    info["rate"] = float(p.get("playbackRate") or 1) if info["playing"] else 0.0
    info["duration"] = float(p.get("duration") or 0)
    info["artwork"] = ART if os.path.exists(ART) else ""
    with open(STATE + ".tmp", "w") as f:
        json.dump(info, f)
    os.replace(STATE + ".tmp", STATE)
    return last_art

def _stream():
    """Follow the system Now Playing feed (works for Spotify, Music, browsers, any player...)."""
    last_key, last_art = None, None
    while True:
        try:
            proc = subprocess.Popen([MEDIA_CONTROL, "stream", "--no-diff"],
                                    stdout=subprocess.PIPE, text=True)
            for line in proc.stdout:
                try:
                    p = json.loads(line).get("payload") or {}
                except ValueError:
                    continue
                last_art = _publish(p, last_art)
                if not p.get("playing") or not p.get("title"):
                    with _lock: _np["state"] = None
                    last_key = None
                    continue
                key = (p.get("title"), p.get("artist"), p.get("elapsedTime"), p.get("timestamp"))
                if key == last_key:
                    continue
                last_key = key
                now = time.time()
                ts = _parse_ts(p.get("timestamp", ""))
                # timestamp only has 1s resolution: trust arrival time for fresh events
                anchor = now if ts is None or now - ts < 1.5 else ts + 0.5
                with _lock:
                    _np["state"] = dict(track=p["title"], artist=p.get("artist", ""),
                                        album=p.get("album", ""), duration=float(p.get("duration") or 0),
                                        position=float(p.get("elapsedTime") or 0),
                                        rate=float(p.get("playbackRate") or 1))
                    _np["anchor"] = anchor
        except Exception:
            pass
        time.sleep(2)

def now_playing():
    with _lock:
        st = _np["state"]
        if not st:
            return None
        st = dict(st)
        st["position"] += (time.time() - _np["anchor"]) * st["rate"]
        return st

def main():
    threading.Thread(target=_stream, daemon=True).start()
    cur_key, lines, last_written, polled_at, as_state = None, None, None, 0, None
    while True:
        state = now_playing()
        if state is None:  # fallback: AppleScript (Spotify / Music)
            if time.time() - polled_at >= 1.0:
                as_state, polled_at = player(), time.time()
            if as_state:
                state = dict(as_state); state["position"] += time.time() - polled_at
        if state:
            k = (state["artist"], state["track"])
            if k != cur_key:
                cur_key, lines = k, None
                write(f"♪ {state['track']} — {state['artist']}")
                lines = lyrics_for(state)
        if not state:
            text = ""
        elif not lines:
            text = f"♪ {state['track']} — {state['artist']}" if setting("showTitleWhenNoLyrics", True) else "♪"
        else:
            pos = state["position"] + float(setting("lyricOffset", 0.35))
            text = ""
            for t, w in lines:
                if t <= pos: text = w
                else: break
            text = text or "♪"
        if text != last_written:
            write(text); last_written = text
        time.sleep(0.2)

if __name__ == "__main__":
    main()
