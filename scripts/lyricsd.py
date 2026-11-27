#!/usr/bin/python3
"""Touch Bar synced lyrics daemon.
Polls Spotify / Apple Music, fetches synced lyrics from lrclib.net,
and writes the current line to ~/.touchbar-lyrics/current.txt (read by MTMR)."""
import datetime, json, os, re, subprocess, sys, threading, time, urllib.parse, urllib.request, hashlib

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
      set r to "playing" & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & ((duration of t) / 1000) & tab & (player position) & tab & "com.spotify.client"
    end if
  end tell
end if
if r is "" and application "Music" is running then
  tell application "Music"
    if player state is playing then
      set t to current track
      set r to "playing" & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & (duration of t) & tab & (player position) & tab & "com.apple.Music"
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
    if len(parts) != 7 or parts[0] != "playing":
        return None
    num = lambda s: float(s.replace(",", "."))
    try:
        return dict(track=parts[1], artist=parts[2], album=parts[3], duration=num(parts[4]), position=num(parts[5]),
                    bundle=parts[6])
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

# Captions of a YouTube video playing in a browser. The browser only reports title, channel and length, so the
# video is found by searching for those (yt-dlp), and only a result with the same title and length is used.
BROWSERS = ("com.apple.safari", "com.apple.webkit", "com.google.chrome", "org.chromium", "org.mozilla", "company.thebrowser",
            "com.microsoft.edgemac", "com.brave.browser", "com.operasoftware", "com.vivaldi", "app.zen-browser",
            "com.kagi.kagimacos", "org.torproject", "net.imput.helium", "ai.perplexity.comet", "com.openai.atlas")

def _is_browser(bundle):
    return bundle.lower().startswith(BROWSERS)

def _ytdlp_path():
    return shutil.which("yt-dlp") or next((x for x in ("/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp") if os.path.exists(x)), None)

def _ytdlp(args, timeout=45):
    exe = _ytdlp_path()
    if not exe:
        return None
    env = dict(os.environ, PATH="/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", "/usr/bin:/bin"))
    r = subprocess.run([exe, "--no-warnings", "--no-playlist", "-J"] + args, capture_output=True, text=True, timeout=timeout, env=env)
    return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else None

def _caption_lines(events):
    """json3 caption events → [(seconds, text, words)], words = [[seconds, word], …] when the captions time each
    word (the automatic ones do), else []. A caption stays up until the next one; after a real gap (nobody
    speaks) the line is cleared. Automatic captions overlap each other, so they never clear."""
    caps = []
    for e in events:
        segs = e.get("segs") or []
        t = (e.get("tStartMs") or 0) / 1000.0
        text = re.sub(r"\s+", " ", "".join(x.get("utf8", "") for x in segs)).strip()
        words = []
        if any("tOffsetMs" in x for x in segs):
            for x in segs:                       # one segment per word (sometimes two words), each with its start
                w = re.sub(r"\s+", " ", x.get("utf8", "")).strip()
                if w:
                    words.append([round(t + (x.get("tOffsetMs") or 0) / 1000.0, 3), w])
            text = " ".join(w for _, w in words)
        if text and not (caps and caps[-1][2] == text):
            caps.append((t, t + (e.get("dDurationMs") or 0) / 1000.0, text, words))
    lines = []
    for i, (t, end, text, words) in enumerate(caps):
        lines.append((t, text, words))
        if end > t and (i + 1 == len(caps) or caps[i + 1][0] - end > 1.5):
            lines.append((end, "", []))
    return lines

_yt = {"wait_until": 0.0}

def captions_for(p):
    """[(seconds, text)] for the video, [] if it has none or isn't found, None if that couldn't be asked."""
    dur = p.get("duration") or 0
    if not p.get("track"):
        return []
    if dur <= 0:
        return []                                # no length, so no telling which video it is
    if time.time() < _yt["wait_until"]:
        return None                              # YouTube said no a moment ago: later
    try:
        found = _ytdlp(["--flat-playlist", "ytsearch5:" + (p["track"] + " " + p.get("artist", "")).strip()])
        if found is None:
            return None if _ytdlp_path() else []     # not installed: no captions; installed but failed: ask again
        norm = lambda s: re.sub(r"\W+", "", (s or "").lower())
        vid = next((e["id"] for e in found.get("entries") or []
                    if e.get("id") and norm(e.get("title")) == norm(p["track"]) and abs((e.get("duration") or 0) - dur) <= 2), None)
        if not vid:
            return []
        info = _ytdlp(["--skip-download", "--ignore-no-formats-error", "https://www.youtube.com/watch?v=" + vid])
        if info is None:
            # usually YouTube asking to "confirm you're not a bot" after many lookups: leave it alone for a while
            _yt["wait_until"] = time.time() + 900
            note("YouTube refused the captions lookup; trying again in 15 minutes")
            return None
        manual, auto = info.get("subtitles") or {}, info.get("automatic_captions") or {}
        manual = {k: v for k, v in manual.items() if k != "live_chat"}
        lang = (info.get("language") or "en").split("-")[0]
        # captions someone wrote, in the video's language; else the automatic ones in the language spoken
        pick = next((manual[k] for k in manual if k.split("-")[0] == lang), None) \
            or auto.get(lang + "-orig") or next((auto[k] for k in auto if k.endswith("-orig")), None) \
            or auto.get(lang) or next(iter(manual.values()), None)
        url = next((f.get("url") for f in pick or [] if f.get("ext") == "json3"), None)
        if not url:
            return []
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=15) as r:
            return _caption_lines(json.loads(r.read()).get("events") or [])
    except (subprocess.TimeoutExpired, OSError, ValueError, KeyError, TypeError) as e:
        note(f"captions lookup failed: {type(e).__name__}")
        return None

def lyrics_for(p):
    captions = _is_browser(p.get("bundle", "")) and bool(setting("videoCaptions", False))
    # videos are remembered apart from songs: "no lyrics" for a title mustn't hide its captions
    key = hashlib.md5((("video2|" if captions else "") + f"{p['artist']}|{p['track']}").lower().encode()).hexdigest()
    path = os.path.join(CACHE, key + ".json")
    try:
        with open(path) as f:
            cached = [tuple(x) for x in json.load(f)]
        # "no lyrics" is only remembered for a week: they may have been added since
        if cached or time.time() - os.stat(path).st_mtime < 7 * 86400:
            return cached
    except FileNotFoundError:
        pass
    except (OSError, ValueError, TypeError):
        try:
            os.remove(path)                      # a damaged file (cut off mid-write): fetch again
        except OSError:
            pass
    synced = None
    dur = p.get("duration") or 0                 # some players report 0 at first
    # a video with no length yet (it usually follows within seconds), or YouTube refusing lookups for now: wait
    # without asking anyone. After a few tries a missing length is taken as final and it goes on as for a song.
    if captions and ((dur <= 0 and p.get("tries", 0) < 3) or (time.time() < _yt["wait_until"] and p.get("tries", 0) > 0)):
        return None
    try:
        params = dict(artist_name=p["artist"], track_name=p["track"], album_name=p["album"])
        if dur > 0:
            params["duration"] = round(dur)
        synced = fetch("https://lrclib.net/api/get?" + urllib.parse.urlencode(params)).get("syncedLyrics")
    except Exception:
        pass
    if not synced:
        try:
            q = urllib.parse.urlencode(dict(artist_name=p["artist"], track_name=p["track"]))
            for r in fetch("https://lrclib.net/api/search?" + q):
                if r.get("syncedLyrics") and (dur <= 0 or abs((r.get("duration") or 0) - dur) < 5):
                    synced = r["syncedLyrics"]; break
        except Exception:
            return None  # network error: don't cache, retry next song change
    lines = parse_lrc(synced)
    if not lines and captions:
        caps = captions_for(p)
        if caps is None:
            return None                          # couldn't ask: try again later, remember nothing
        lines = caps
    if dur > 0:                                  # without the length the match is a guess: don't remember it
        tmp = f"{path}.{os.getpid()}.tmp"
        with open(tmp, "w") as f:
            json.dump(lines, f)
        os.replace(tmp, path)                    # never leave a half-written file for the next read
    return lines

def write(text, clip=True):
    if clip and len(text) > MAXLEN:
        text = text[:MAXLEN - 1] + "…"
    tmp = OUT + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, OUT)

import shutil
def media_control():
    """Homebrew lives in /opt/homebrew on Apple silicon and /usr/local on Intel (most Touch Bar Macs).
    Looked up each time, so installing it later is picked up without a restart."""
    return next((p for p in ("/opt/homebrew/bin/media-control", "/usr/local/bin/media-control")
                 if os.path.exists(p)), shutil.which("media-control"))

_said = set()
def note(msg):
    """One line per distinct problem in error.log (launchd sends stderr there)."""
    if msg not in _said:
        _said.add(msg)
        print(time.strftime("%Y-%m-%d %H:%M:%S"), "lyricsd:", msg, file=sys.stderr, flush=True)

_np = {"state": None, "anchor": 0.0, "up": False}
_lock = threading.Lock()

def _parse_ts(ts):
    try:
        return datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc).timestamp()
    except Exception:
        return None

def _times(p):
    """(elapsed, anchor, duration): elapsed was the position at time `anchor`.
    With --micros the timestamp is exact; the plain one only has 1 s resolution, so fresh events are
    anchored at arrival instead (which runs late by however long the event took to arrive)."""
    now = time.time()
    if "elapsedTimeMicros" in p or "timestampEpochMicros" in p or "durationMicros" in p:
        ts = p.get("timestampEpochMicros")
        return (float(p.get("elapsedTimeMicros") or 0) / 1e6, min(now, float(ts) / 1e6) if ts else now,
                float(p.get("durationMicros") or 0) / 1e6)
    ts = _parse_ts(p.get("timestamp", ""))
    return (float(p.get("elapsedTime") or 0), now if ts is None or now - ts < 1.5 else ts + 0.5,
            float(p.get("duration") or 0))

STATE = os.path.join(HOME, "state.json")
WORDS = os.path.join(HOME, "words.json")      # {"text": line, "words": [[seconds, word], …]} for the line in current.txt
ART = os.path.join(HOME, "artwork.jpg")

def _publish(p, last_art):
    """Write playback state + artwork for the Touch Bar app."""
    import base64
    info = {"playing": bool(p.get("playing")), "title": p.get("title", ""), "artist": p.get("artist", ""),
            "album": p.get("album", ""), "bundle": p.get("bundleIdentifier", "")}
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
    info["elapsed"], info["anchor"], info["duration"] = _times(p)
    info["rate"] = float(p.get("playbackRate") or 1) if info["playing"] else 0.0
    info["artwork"] = ART if os.path.exists(ART) else ""
    with open(STATE + ".tmp", "w") as f:
        json.dump(info, f)
    os.replace(STATE + ".tmp", STATE)
    return last_art

def _keep_times(p, last):
    """Browsers send some updates (pause, resume, a metadata change) with no position or length at all. Read as
    they stand those mean "back at 0:00", so for the same item the position carries on from the last one known.
    Returns what to remember for the next event."""
    key, now = (p.get("bundleIdentifier"), p.get("title")), time.time()
    if "elapsedTimeMicros" in p or "elapsedTime" in p:
        el, anchor, dur = _times(p)
    elif last and last["key"] == key and p.get("title") and _is_browser(p.get("bundleIdentifier") or ""):
        el = last["el"] + (now - last["anchor"]) * last["rate"]
        dur = _times(p)[2] or last["dur"]
        if dur > 0:
            el = min(el, dur)
        anchor = now
        p["elapsedTimeMicros"], p["timestampEpochMicros"] = int(el * 1e6), int(now * 1e6)
        p["durationMicros"] = int(dur * 1e6)
    else:
        return None
    return dict(key=key, el=el, anchor=anchor, dur=dur,
                rate=float(p.get("playbackRate") or 1) if p.get("playing") else 0.0)

MUSIC_APPS = ("com.spotify.client", "com.apple.Music")       # can be asked directly whether they still play

def _stream():
    """Follow the system Now Playing feed (works for Spotify, Music, browsers, any player...).

    Music comes before browsers: macOS hands Now Playing to whatever started last, so a video (or a silent
    thumbnail preview) in a browser would push the song off the bar. While Spotify or Music is playing,
    browser items are held back; the latest one is let through when the music stops. (LyricsBar's own player
    is handled by the app, which knows its player directly, and by now_playing() below for the lyrics.)"""
    s = dict(key=None, art=None, timing=None, shown=("", False), held=None)
    gate = threading.Lock()                      # events are handled one at a time (the stream and the watcher below)
    micros = True                                # exact timestamps; dropped if this media-control can't do them

    def hold(p):
        """True if this browser item has to wait because music is playing."""
        if not (p.get("title") and _is_browser(p.get("bundleIdentifier") or "") and setting("musicOverBrowsers", True)):
            s["held"] = None
            return False
        bundle, playing = s["shown"]
        # already holding: the watcher keeps checking; otherwise ask the app once
        if playing and bundle in MUSIC_APPS and (s["held"] is not None or player() is not None):
            s["held"] = p
            return True
        s["held"] = None
        return False

    def handle(p):
        try:
            s["timing"] = _keep_times(p, s["timing"])
            s["art"] = _publish(p, s["art"])
        except (ValueError, TypeError, OSError):
            return                               # one odd event (or a failed write) must not restart the stream
        s["shown"] = (p.get("bundleIdentifier") or "", bool(p.get("playing")))
        if not p.get("title"):
            with _lock: _np["state"] = None
            s["key"] = None
            return
        paused = not p.get("playing")            # keep the song while paused so its lyric line stays up
        # the rate matters too: buffering (0) → playing (1) at the same position must restart the clock
        key = (p.get("title"), p.get("artist"), p.get("elapsedTimeMicros", p.get("elapsedTime")),
               p.get("timestampEpochMicros", p.get("timestamp")), paused, p.get("playbackRate"))
        if key == s["key"]:
            return
        s["key"] = key
        now = time.time()
        try:
            position, anchor, duration = _times(p)
            st = dict(track=p["title"], artist=p.get("artist", ""), bundle=p.get("bundleIdentifier", ""),
                      album=p.get("album", ""), duration=duration, position=position,
                      rate=0.0 if paused else float(p.get("playbackRate") or 1))
        except (TypeError, ValueError):
            return
        with _lock:
            h = _np.get("hint")
            if h and now - h[1] < 1.5 and not paused and _np["state"] \
                    and _np["state"]["track"] == st["track"] \
                    and abs(st["position"] + (now - anchor) * st["rate"] - (h[0] + (now - h[1]))) > 2:
                return               # an update still from before the seek: the seek hint stands
            _np["state"] = st
            _np["anchor"] = anchor

    def watch():
        """While a browser item is held back: is the music still playing? Spotify and Music send nothing through
        the feed meanwhile (the browser owns it), so their song and position are asked for directly."""
        while True:
            time.sleep(4)
            if s["held"] is None:
                continue
            try:
                with gate:
                    p = s["held"]
                    if p is None:
                        continue
                    bundle, playing = s["shown"]
                    m = player() if playing and bundle in MUSIC_APPS else None
                    if m is None:                            # the music stopped: the browser's turn
                        s["held"] = None
                        handle(p)
                        continue
                    with _lock:
                        st = _np["state"]
                        est = st["position"] + (time.time() - _np["anchor"]) * st["rate"] if st else None
                        same = bool(st) and st["track"] == m["track"] and abs(est - m["position"]) < 2
                    if not same:                             # next song, or a seek, that the feed didn't report
                        now = int(time.time() * 1e6)
                        handle({"title": m["track"], "artist": m["artist"], "album": m["album"], "bundleIdentifier": m["bundle"],
                                "playing": True, "playbackRate": 1, "durationMicros": int(m["duration"] * 1e6),
                                "elapsedTimeMicros": int(m["position"] * 1e6), "timestampEpochMicros": now})
            except Exception as e:
                note(f"held-back watcher: {type(e).__name__}")
    threading.Thread(target=watch, daemon=True).start()

    while True:
        proc, got = None, False
        try:
            mc = media_control()
            if not mc:
                note("media-control isn't installed (brew install media-control): no lyrics or song info until it is")
                time.sleep(8)
                continue
            proc = subprocess.Popen([mc, "stream", "--no-diff"] + (["--micros"] if micros else []),
                                    stdout=subprocess.PIPE, text=True)
            for line in proc.stdout:
                got = True
                _np["up"] = True
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                p = (msg.get("payload") if isinstance(msg, dict) else None) or {}
                if not isinstance(p, dict):
                    continue
                with gate:
                    if not hold(p):
                        handle(p)
        except Exception as e:
            note(f"media-control stream failed: {type(e).__name__}")
        finally:
            _np["up"] = False
            with gate:
                s["held"] = None
            with _lock:
                _np["state"] = None              # nothing is known while the stream is down
            if proc is not None:                 # never leave an old media-control running
                try:
                    proc.kill(); proc.wait(timeout=5)
                except Exception:
                    pass
                if micros and not got:
                    micros = False               # it ran but printed nothing: an older one without --micros
                    note("media-control printed nothing with --micros; using plain timestamps")
        time.sleep(2)

CLOCK = os.path.join(HOME, "clock.json")
_clock = {"mtime": None, "value": None}

def _own_clock():
    """LyricsBar's built-in player writes its exact position on every change (Now Playing lags behind)."""
    try:
        m = os.stat(CLOCK).st_mtime
    except OSError:
        return None
    if m != _clock["mtime"]:
        _clock["mtime"] = m
        try:
            with open(CLOCK) as f:
                c = json.load(f)
            _clock["value"] = dict(bundle=c["bundle"], track=c["title"], artist=c["artist"],
                                   album=c.get("album", ""), duration=float(c.get("duration") or 0),
                                   position=float(c["position"]), at=float(c["at"]), rate=float(c["rate"]))
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            _clock["value"] = None
    return _clock["value"]

def now_playing():
    with _lock:
        st = _np["state"]
        if not st:
            return None
        st = dict(st)
        st["position"] += (time.time() - _np["anchor"]) * st["rate"]
    c, now = _own_clock(), time.time()
    # LyricsBar is the Now Playing app: its own clock is the truth (song included: Now Playing lags behind
    # on song changes and crossfades too). While playing it's rewritten at least every 10 s, so an older
    # one is from a LyricsBar that quit or hung.
    # The same goes while LyricsBar plays and a browser holds Now Playing (a video, or a silent preview):
    # the bar stays on the music, so the lyrics do too.
    fresh = now - c["at"] < 20 if c else False
    if c and c["bundle"] and ((c["bundle"] == st.get("bundle") and (c["rate"] == 0 or fresh))
                              or (c["rate"] > 0 and fresh and _is_browser(st.get("bundle", ""))
                                  and setting("musicOverBrowsers", True))):
        st.update(track=c["track"], artist=c["artist"], album=c["album"], duration=c["duration"], bundle=c["bundle"],
                  rate=c["rate"], position=c["position"] + (now - c["at"]) * c["rate"])
    return st

OUTPUT = os.path.join(HOME, "output.json")
_out = {"mtime": None, "airplay": False}

def _airplay():
    """LyricsBar writes output.json when the sound moves to or from an AirPlay speaker."""
    try:
        m = os.stat(OUTPUT).st_mtime
    except OSError:
        return False
    if m != _out["mtime"]:
        _out["mtime"] = m
        try:
            with open(OUTPUT) as f:
                _out["airplay"] = bool(json.load(f).get("airplay"))
        except (OSError, ValueError, AttributeError):
            _out["airplay"] = False
    return _out["airplay"]

SEEK = os.path.join(HOME, "seek.json")

def _apply_seek(seen):
    """LyricsBar writes seek.json when it seeks; the Now Playing feed often stays quiet about seeks."""
    try:
        m = os.stat(SEEK).st_mtime
    except OSError:
        return seen
    if m == seen:
        return seen
    try:
        with open(SEEK) as f:
            s = json.load(f)
        pos, at = float(s["position"]), float(s["at"])
    except (OSError, ValueError, KeyError, TypeError):
        return m
    if time.time() - at < 3:
        with _lock:
            if _np["state"] and _np["anchor"] < at:
                _np["state"]["position"], _np["anchor"] = pos, at
                _np["hint"] = (pos, at)
    return m

_found = {}                                      # song key → lines ([] = none, None = lookup failed)

def _lookup(key, st):
    """Runs off the main loop: a slow network must not freeze the line on screen."""
    try:
        res = lyrics_for(st)
    except Exception as e:
        note(f"lyrics lookup failed: {type(e).__name__}")
        res = None
    with _lock:
        _found[key] = res

def main():
    threading.Thread(target=_stream, daemon=True).start()
    cur_key, lines, last_written, polled_at, as_state = None, None, None, 0, None
    looking, tries, retry_at = False, 0, 0.0
    seek_seen, had_words = None, True
    while True:
        try:
            seek_seen = _apply_seek(seek_seen)
            state = now_playing()
            # fallback, only while the Now Playing stream is down: ask Spotify / Music directly, now and then
            if state is None and not _np["up"]:
                if time.time() - polled_at >= 5.0:
                    as_state, polled_at = player(), time.time()
                if as_state:
                    state = dict(as_state); state["position"] += time.time() - polled_at
            if state:
                k = (state["artist"], state["track"])
                if k != cur_key:
                    cur_key, lines, looking, tries, retry_at = k, None, False, 0, 0.0
                    with _lock:
                        _found.clear()
                    last_written = f"♪ {state['track']} — {state['artist']}"
                    write(last_written, clip=False)
                if lines is None and not looking and time.time() >= retry_at:
                    looking = True
                    threading.Thread(target=_lookup, args=(k, dict(state, tries=tries)), daemon=True).start()
                if looking:
                    with _lock:
                        done, got = k in _found, _found.pop(k, None)
                    if done:
                        looking = False
                        if got is None:          # the network failed: try again shortly, not only on the next song
                            tries += 1
                            retry_at = time.time() + (5, 30, 120)[min(tries, 3) - 1]
                        else:
                            lines = got
            title, words = False, []
            if not state:
                text = ""
            elif not lines:
                title = bool(setting("showTitleWhenNoLyrics", True))
                text = f"♪ {state['track']} — {state['artist']}" if title else "♪"
            else:
                pos = state["position"] + float(setting("lyricOffset", 0.35))
                if _airplay():                   # AirPlay speakers play late and don't say by how much
                    pos -= max(0.0, float(setting("airplayLyricDelay", 1.0)))
                text = ""
                for ln in lines:
                    if ln[0] <= pos: text, words = ln[1], (ln[2] if len(ln) > 2 else [])
                    else: break
                text = text or "♪"
            if text != last_written:
                # word times of the line on screen, for the bar to light the words up as they're said
                wtext = text if len(text) <= MAXLEN and words and text != "♪" else ""
                if wtext or had_words:
                    with open(WORDS + ".tmp", "w") as f:
                        json.dump({"text": wtext, "words": words if wtext else []}, f)
                    os.replace(WORDS + ".tmp", WORDS)
                    had_words = bool(wtext)
                write(text, clip=not title); last_written = text
        except Exception as e:                   # one bad pass must not take the daemon down (launchd would loop it)
            note(f"main loop: {type(e).__name__}: {e}")
        time.sleep(0.2)

if __name__ == "__main__":
    main()
