#!/usr/bin/python3
"""Playlist providers for LyricsBar.

  library.py providers                  -> [{"id","name","ready"}]
  library.py playlists <provider>       -> [{"id","name","count"}]   (subsonic | spotify | applemusic)
  library.py tracks subsonic <id>       -> [{"id","title","artist","album","duration","stream","cover"}]
  library.py queue spotify              -> [{"title","artist","album","uri","duration","image"}]
  library.py spotify-jump <uri> <index> -> skip forward to that queued song
  library.py spotify-queue-playlist <uri> -> add a playlist's songs (max 100) to the end of the queue
  library.py spotify-replace <uri>...   -> replay current song + this list (remove / reorder)
  library.py spotify-feed [--peek] <uri> -> make this song Spotify's next (--peek: only check); reports its first
  library.py spotify-login <client_id>  -> one-time Spotify sign-in (opens the browser)
"""
import base64, hashlib, http.server, json, os, re, secrets, subprocess, sys, time
import urllib.error, urllib.parse, urllib.request

HOME = os.path.expanduser("~/.touchbar-lyrics")
UA = "LyricsBar/1.0"  # the server's firewall blocks Python's default User-Agent
REDIRECT = "http://127.0.0.1:8898/callback"


def http_json(url, data=None, headers=None):
    req = urllib.request.Request(url, data=data, headers={"User-Agent": UA, **(headers or {})})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())


# Credentials come from the app's Keychain item on stdin; this script never stores them.
# Refreshed tokens go back to the app in the output as {"__creds": {...}} so it can update the Keychain.
CREDS = {}
UPDATED = {}

def load_creds():
    global CREDS
    if not sys.stdin.isatty():
        try:
            CREDS = json.loads(sys.stdin.read() or "{}")
        except ValueError:
            CREDS = {}

def cred(name):
    c = CREDS.get(name)
    if not c:
        raise RuntimeError(f"{name.capitalize()} isn't connected. Connect it under Providers.")
    return c


# ---------------- Subsonic / Navidrome ----------------

def sub_cfg():
    return cred("subsonic")


def sub_url(endpoint, json_format=True, **params):
    c = sub_cfg()
    q = dict(u=c["u"], t=c["t"], s=c["s"], v="1.16.1", c="lyricsbar", **params)
    if json_format:
        q["f"] = "json"
    return f'{c["server"]}/rest/{endpoint}?{urllib.parse.urlencode(q)}'


def sub(endpoint, **params):
    r = http_json(sub_url(endpoint, **params))["subsonic-response"]
    if r.get("status") != "ok":
        raise RuntimeError(r.get("error", {}).get("message", "subsonic error"))
    return r


def subsonic_playlists():
    pls = sub("getPlaylists").get("playlists", {}).get("playlist", [])
    return [{"id": p["id"], "name": p["name"], "count": p.get("songCount", 0)} for p in pls]


def subsonic_tracks(pid):
    entries = sub("getPlaylist", id=pid)["playlist"].get("entry", [])
    out = []
    for e in entries:
        out.append({
            "id": e["id"], "title": e.get("title", ""), "artist": e.get("artist", ""),
            "album": e.get("album", ""), "duration": e.get("duration", 0),
            "stream": sub_url("stream", json_format=False, id=e["id"]),
            "cover": sub_url("getCoverArt", json_format=False, id=e.get("coverArt", e["id"]), size=300),
        })
    return out


# ---------------- Spotify (Web API for listing, Spotify.app for playback) ----------------

def spotify_token():
    c = dict(cred("spotify"))
    if float(c.get("expires", 0)) - 60 > time.time():
        return c["access_token"]
    body = urllib.parse.urlencode(dict(grant_type="refresh_token", refresh_token=c["refresh_token"],
                                       client_id=c["client_id"])).encode()
    try:
        t = http_json("https://accounts.spotify.com/api/token", data=body,
                      headers={"Content-Type": "application/x-www-form-urlencoded"})
    except urllib.error.HTTPError as e:
        if e.code in (400, 401):                           # invalid_grant: the login was revoked or expired
            raise RuntimeError("Spotify's login expired: reconnect it in Settings → Providers")
        raise
    c["access_token"] = t["access_token"]
    c["expires"] = time.time() + t.get("expires_in", 3600)
    if t.get("refresh_token"):
        c["refresh_token"] = t["refresh_token"]
    CREDS["spotify"] = UPDATED["spotify"] = {k: str(v) for k, v in c.items()}
    return c["access_token"]


def spotify_playlists():
    tok = spotify_token()
    me = http_json("https://api.spotify.com/v1/me", headers={"Authorization": f"Bearer {tok}"})
    out = [{"id": f"spotify:user:{me['id']}:collection", "name": "Liked Songs", "count": 0}]
    url = "https://api.spotify.com/v1/me/playlists?limit=50"
    while url:
        r = http_json(url, headers={"Authorization": f"Bearer {tok}"})
        for p in r.get("items", []):
            if p:
                n = (p.get("tracks") or p.get("items") or {}).get("total", 0)
                out.append({"id": p["uri"], "name": p["name"], "count": n})
        url = r.get("next")
    return out


SPOTIFY_URI = re.compile(r"^spotify:(track|episode):[A-Za-z0-9]{22}$")
LISTED_URI = re.compile(r"^spotify:[!-~]{1,390}$")        # anything Spotify lists (local files too), printable ASCII


def spotify_api(method, path, body=None, _retried=False):
    """Call the Spotify Web API; returns parsed JSON or None (204). Raises RuntimeError with a readable reason."""
    tok = spotify_token()
    data = json.dumps(body).encode() if body is not None else (b"" if method in ("POST", "PUT") else None)
    req = urllib.request.Request("https://api.spotify.com/v1" + path, data=data, method=method, headers={
        "User-Agent": UA, "Authorization": f"Bearer {tok}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            raw = r.read()
            try:
                return json.loads(raw) if raw.strip() else None
            except ValueError:                             # some player endpoints answer 200 with a non-JSON body
                return None
    except urllib.error.HTTPError as e:
        if e.code == 429 and not _retried:                 # rate limited: wait as asked (briefly) and try once more
            try:
                wait = min(float(e.headers.get("Retry-After") or 1), 5)
            except ValueError:
                wait = 1
            time.sleep(wait)
            return spotify_api(method, path, body, _retried=True)
        try:
            msg = json.loads(e.read()).get("error", {}).get("message", "")
        except Exception:
            msg = ""
        if e.code in (401, 403) and "scope" in msg.lower():
            raise RuntimeError("Spotify needs new permissions: reconnect it in Settings → Providers (scope)")
        if e.code == 403 and path.startswith("/me/player"):
            raise RuntimeError("Spotify only allows queue changes with Premium" + (f" ({msg})" if msg else ""))
        if e.code == 403:
            raise RuntimeError("Spotify won't let this app read that" + (f" ({msg})" if msg else ""))
        if e.code == 404 and path.startswith("/me/player"):
            raise RuntimeError("Spotify isn't playing on any device right now")
        if e.code == 404:
            raise RuntimeError("Spotify couldn't find that" + (f" ({msg})" if msg else ""))
        raise RuntimeError(f"Spotify answered {e.code}" + (f": {msg}" if msg else ""))


def _track(t):
    people = t.get("artists") or ([t["show"]] if t.get("show") else [])   # songs have artists, podcasts a show
    album = t.get("album") or t.get("show") or {}
    imgs = album.get("images") or t.get("images") or []
    img = min(imgs, key=lambda i: i.get("width") or 9999).get("url", "") if imgs else ""
    return {"title": t.get("name", "?"), "artist": ", ".join(a.get("name", "") for a in people),
            "album": album.get("name", ""), "uri": t.get("uri", ""), "duration": (t.get("duration_ms") or 0) / 1000,
            "image": img if img.startswith("https://") else ""}


def spotify_queue():
    r = spotify_api("GET", "/me/player/queue") or {}
    return [_track(t) for t in r.get("queue", []) if t]


def spotify_jump(uri, hint):
    """Play a queued song now. Spotify's API only has "next", so skip to it, with Spotify muted while it
    passes the songs in between (one at a time was audible). Skipping keeps Spotify's own queue and playlist
    intact; replaying from the target confuses Spotify's queue listing. Finds the song in the queue as it is
    *now*; `hint` picks the right copy when the same song is queued twice."""
    if not LISTED_URI.match(uri):
        raise RuntimeError("invalid song")
    hint = int(hint)
    q = [t.get("uri") for t in (spotify_api("GET", "/me/player/queue") or {}).get("queue", []) if t]
    found = [i for i, u in enumerate(q) if u == uri]
    if not found:
        raise RuntimeError("That song isn't in Spotify's queue any more")
    n = min(found, key=lambda k: abs(k - hint)) + 1
    if n > 50:
        raise RuntimeError("That song is too far down the queue to skip to")
    st = spotify_api("GET", "/me/player") or {}
    dev = urllib.parse.quote((st.get("device") or {}).get("id") or "", safe="")
    vol = _spotify_volume(st, dev) if n > 1 else None
    if vol is not None:
        _spotify_volume(st, dev, 0)
    try:
        _spotify_skip(st, n)
    finally:
        if vol is not None:
            time.sleep(0.4)                                # let the last skip land before the sound comes back
            _spotify_unmute(st, dev, vol)
    return {"skipped": n}


def spotify_queue_playlist(pid):
    """Add a playlist's songs (or Liked Songs) to the end of the queue. Capped at 100: one request per song."""
    # Liked Songs comes as "spotify:collection" (the user id isn't needed, and may hold characters we strip)
    if not re.match(r"^spotify:(playlist:[A-Za-z0-9]{1,64}|collection|user:[A-Za-z0-9._-]{1,64}:collection)$", pid):
        raise RuntimeError("invalid playlist")
    st = spotify_api("GET", "/me/player")
    if not st or not st.get("device"):
        raise RuntimeError("Spotify isn't playing on any device right now")
    dev = urllib.parse.quote(st["device"].get("id") or "", safe="")
    if pid.endswith(":collection"):
        url = "/me/tracks?limit=50"
    else:
        url = f"/playlists/{pid.split(':')[-1]}/items?limit=50"     # the current endpoint (".../tracks" is legacy)
    uris = []
    while url and len(uris) < 100:
        try:
            r = spotify_api("GET", url) or {}
        except RuntimeError as e:
            if "won't let" in str(e):        # personal (development-mode) apps can only read playlists you own
                raise RuntimeError("Spotify only lets LyricsBar read playlists you made, not ones you follow")
            raise
        for it in r.get("items", []):
            it = it or {}
            u = ((it.get("item") or it.get("track")) or {}).get("uri", "")
            if SPOTIFY_URI.match(u):
                uris.append(u)
        nxt = r.get("next") or ""
        url = nxt[len("https://api.spotify.com/v1"):] if nxt.startswith("https://api.spotify.com/v1/") else None
    uris = uris[:100]
    done = 0
    for u in uris:
        try:
            spotify_api("POST", f"/me/player/queue?uri={urllib.parse.quote(u, safe='')}&device_id={dev}")
        except RuntimeError as e:
            if done == 0:
                raise
            return {"queued": done, "total": len(uris), "error": str(e)}   # say how far it got
        done += 1
        time.sleep(0.05)
    return {"queued": done, "total": len(uris)}


def _spotify_local(st):
    """True when Spotify plays in the Spotify app on this Mac, so AppleScript reaches the right player."""
    d = (st or {}).get("device") or {}
    if (d.get("type") or "").lower() != "computer":
        return False
    try:
        if subprocess.run(["/usr/bin/pgrep", "-x", "Spotify"], capture_output=True, timeout=5).returncode != 0:
            return False                                   # don't let AppleScript launch the app
        name = subprocess.run(["/usr/sbin/scutil", "--get", "ComputerName"], capture_output=True, text=True,
                              timeout=5).stdout.strip()
    except Exception:
        return False
    return bool(name) and name == d.get("name")


def _spotify_volume(st, dev, v=None):
    """Read (v=None) or set Spotify's volume: the app's own through AppleScript when it plays here, else the
    device's through the Web API. Reading returns None when unknown."""
    if _spotify_local(st):
        script = 'tell application "Spotify" to get sound volume' if v is None else \
                 f'tell application "Spotify" to set sound volume to {int(v)}'
        try:
            r = subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True, text=True, timeout=5)
            if v is not None:
                return None if r.returncode == 0 else False
            return int(r.stdout.strip()) if r.stdout.strip().isdigit() else None
        except Exception:
            return None if v is None else False
    if v is None:
        p = ((st or {}).get("device") or {}).get("volume_percent")
        return int(p) if isinstance(p, (int, float)) else None
    try:
        spotify_api("PUT", f"/me/player/volume?volume_percent={int(v)}&device_id={dev}")
    except Exception:                                      # a dropped connection raises URLError, not RuntimeError
        return False
    return None


def _spotify_unmute(st, dev, vol):
    """Put the volume back after a muted edit. Must not fail quietly: Spotify would stay silent."""
    if vol is None:
        return
    for attempt in range(3):
        try:
            if _spotify_volume(st, dev, vol) is not False:
                return
        except Exception:
            pass
        time.sleep(1 + attempt)


def _spotify_skip(st, n):
    """Go n songs ahead: the Spotify app's own "next" when it plays here (fast, no rate limit), else the API."""
    n = int(n)
    if n <= 0:
        return
    if _spotify_local(st):
        script = f'tell application "Spotify"\nrepeat {n} times\nnext track\ndelay 0.08\nend repeat\nend tell'
        try:
            if subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True, text=True,
                              timeout=60).returncode == 0:
                return
        except Exception:
            pass
        raise RuntimeError("Couldn't control the Spotify app. Allow LyricsBar under System Settings → Privacy → Automation")
    for _ in range(n):
        spotify_api("POST", "/me/player/next")
        time.sleep(0.12)


def spotify_feed(uri, peek=False):
    """LyricsBar keeps its own Up Next and hands Spotify one song shortly before the current one ends.
    If Spotify would play this song next anyway, nothing is added. Otherwise (unless `peek`) it's added to
    Spotify's queue. Returns what Spotify then lists first: if that isn't this song, something else is queued
    ahead of it (songs added in the Spotify app), and LyricsBar switches songs itself instead."""
    if not SPOTIFY_URI.match(uri):
        raise RuntimeError("invalid song")
    q = _queue_uris()
    if (q and q[0] == uri) or peek:
        return {"first": q[0] if q else None, "added": False}
    spotify_api("POST", "/me/player/queue?uri=" + urllib.parse.quote(uri, safe=""))
    first = None
    for _ in range(3):                                     # the listing takes a moment to show the new song
        time.sleep(0.35)
        q = _queue_uris()
        first = q[0] if q else None
        if uri in q[:3]:
            break
    return {"first": first, "added": True}


def _queue_uris():
    return [t.get("uri") for t in (spotify_api("GET", "/me/player/queue") or {}).get("queue", []) if t]


def spotify_replace(uris, keep_current=True):
    """Set Up Next to exactly `uris` (empty = clear), keeping the current song where it is.
    keep_current=False is used at the end of a song (and for Play Now): play `uris` straight away instead,
    or stop if it's empty.

    Spotify's Web API can only add to the queue. Songs added with "Add to queue" sit in a separate queue
    that survives starting new music, so replaying a new list alone doesn't remove them. So, with Spotify
    muted: skip through everything queued (that empties it), start the current song again followed by the
    new list, seek back to the same spot, then unmute (and pause again if it was paused)."""
    if len(uris) > 100 or not all(SPOTIFY_URI.match(u) for u in uris):
        raise RuntimeError("invalid song list")
    st = spotify_api("GET", "/me/player")
    if not st or not st.get("item") or not st.get("device"):
        raise RuntimeError("Spotify isn't playing on any device right now")
    playing = bool(st.get("is_playing"))
    dev = urllib.parse.quote(st["device"].get("id") or "", safe="")
    cur = st["item"].get("uri") or ""
    if not SPOTIFY_URI.match(cur):                          # check before touching anything
        raise RuntimeError("Spotify can't re-queue the song that's playing (a local file), so Up Next can't be edited now")
    pos = st.get("progress_ms") or 0
    t0 = time.time()
    vol = _spotify_volume(st, dev)
    if vol is not None:                                    # never mute without knowing what to restore
        _spotify_volume(st, dev, 0)
    skipped = played = done = False                        # how far the edit got, for putting things back if it fails
    try:
        if st.get("shuffle_state"):                        # a shuffled list would scramble the new order
            spotify_api("PUT", f"/me/player/shuffle?state=false&device_id={dev}")
        # cleared at the end of a song: nothing follows, so leave the finished song stopped at its start
        play = ([cur] + uris) if keep_current or not uris else uris
        for _ in range(3):                                 # the queue listing shows at most ~20 songs at a time
            q = _queue_uris()
            if q:
                skipped, played = True, False
                _spotify_skip(st, len(q))
                time.sleep(0.4)
            spotify_api("PUT", f"/me/player/play?device_id={dev}", {"uris": play})
            played = True
            time.sleep(0.6)
            after, rest = _queue_uris(), play[1:]
            # done once Up Next starts with the new list (or, for a clear, holds none of the songs we skipped)
            if (rest and after[:3] == rest[:3]) or (not rest and not set(after[:5]) & set(q)):
                break
        else:
            raise RuntimeError("Spotify didn't take that change. Try again")
        if not keep_current and not uris:
            spotify_api("PUT", f"/me/player/pause?device_id={dev}")
            playing = True                                 # already paused on purpose
            spotify_api("PUT", f"/me/player/seek?position_ms=0&device_id={dev}")
        elif keep_current:
            # the desktop app ignores position_ms and restarts the song, so seek back to where it was
            # (plus the time this took, if it was playing)
            now = pos + (int((time.time() - t0) * 1000) if playing else 0)
            spotify_api("PUT", f"/me/player/seek?position_ms={now}&device_id={dev}")
        done = True
    finally:
        try:
            if not done and (skipped or played):
                # the edit failed part-way: the song was skipped away from or started again from 0:00.
                # Put it back where it was before the sound returns (best effort).
                try:
                    if not played:
                        spotify_api("PUT", f"/me/player/play?device_id={dev}", {"uris": [cur]})
                        time.sleep(0.4)
                    now = pos + (int((time.time() - t0) * 1000) if playing else 0)
                    spotify_api("PUT", f"/me/player/seek?position_ms={now}&device_id={dev}")
                except Exception:
                    pass
            # whatever happened, a song that was paused must not come back playing out loud
            if not playing:
                try:
                    spotify_api("PUT", f"/me/player/pause?device_id={dev}")
                except Exception:                          # offline raises URLError: still unmute below
                    pass
        finally:
            if vol is not None:
                time.sleep(0.4)                            # let the seek/pause land before the sound comes back
                _spotify_unmute(st, dev, vol)
    return {"count": len(uris)}


def spotify_login(client_id):
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    auth = "https://accounts.spotify.com/authorize?" + urllib.parse.urlencode(dict(
        client_id=client_id, response_type="code", redirect_uri=REDIRECT, state=state,
        code_challenge_method="S256", code_challenge=challenge,
        scope="playlist-read-private playlist-read-collaborative user-library-read user-read-playback-state user-read-currently-playing user-modify-playback-state"))
    got = {}

    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            q = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(self.path).query))
            if q.get("state") == state:
                got.update(q)
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            msg = "LyricsBar is connected to Spotify. You can close this tab." if "code" in got else "Sign-in failed."
            self.wfile.write(f"<h2 style='font-family:-apple-system'>{msg}</h2>".encode())

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 8898), H)
    srv.timeout = 5
    subprocess.run(["open", auth])
    print("Waiting for Spotify sign-in in your browser…")
    deadline = time.time() + 180          # give up (and free the port) if the tab is closed
    try:
        while not got and time.time() < deadline:
            srv.handle_request()
    finally:
        srv.server_close()
    if not got:
        sys.exit("Spotify sign-in timed out. Try Connect again.")
    if "code" not in got:
        sys.exit("Spotify sign-in failed: " + got.get("error", "unknown error"))
    body = urllib.parse.urlencode(dict(grant_type="authorization_code", code=got["code"], redirect_uri=REDIRECT,
                                       client_id=client_id, code_verifier=verifier)).encode()
    t = http_json("https://accounts.spotify.com/api/token", data=body,
                  headers={"Content-Type": "application/x-www-form-urlencoded"})
    CREDS["spotify"] = UPDATED["spotify"] = dict(client_id=client_id, refresh_token=t["refresh_token"],
                                                 access_token=t["access_token"], expires=str(time.time() + t.get("expires_in", 3600)))
    try:
        msg = f"Connected. Found {len(spotify_playlists()) - 1} playlists."
    except Exception:
        msg = "Connected."                # keep the new tokens even if listing fails
    print(json.dumps({"__creds": UPDATED, "message": msg}))


# ---------------- CLI ----------------

# ---------------- Apple Music (Music.app via AppleScript) ----------------

MUSIC_APP = "/System/Applications/Music.app"

def applemusic_playlists():
    if not os.path.exists(MUSIC_APP):
        raise RuntimeError("Music isn't installed")
    script = """
tell application "Music"
  set out to ""
  repeat with p in (every user playlist whose special kind is none)
    set out to out & (persistent ID of p) & tab & (name of p) & tab & (count of tracks of p) & linefeed
  end repeat
  return out
end tell"""
    r = subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or "Couldn't read Music playlists")
    out = []
    for line in r.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 3 and parts[1]:
            out.append({"id": parts[0], "name": parts[1], "count": int(parts[2]) if parts[2].isdigit() else 0})
    return out


def providers():
    return [
        {"id": "subsonic", "name": "Subsonic", "ready": bool(CREDS.get("subsonic"))},
        {"id": "spotify", "name": "Spotify", "ready": bool(CREDS.get("spotify"))},
    ]


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    load_creds()
    try:
        if cmd == "providers":
            res = providers()
        elif cmd == "playlists" and argv[2] == "subsonic":
            res = subsonic_playlists()
        elif cmd == "playlists" and argv[2] == "spotify":
            res = spotify_playlists()
        elif cmd == "playlists" and argv[2] == "applemusic":
            res = applemusic_playlists()
        elif cmd == "queue" and argv[2] == "spotify":
            res = spotify_queue()
        elif cmd == "spotify-queue-playlist":
            res = spotify_queue_playlist(argv[2])
        elif cmd == "spotify-jump":
            res = spotify_jump(argv[2], argv[3])
        elif cmd == "spotify-feed":
            peek = argv[2] == "--peek"                       # only look: is this song Spotify's next already?
            res = spotify_feed(argv[3] if peek else argv[2], peek)
        elif cmd == "spotify-replace":
            start = len(argv) > 2 and argv[2] == "--start"   # start the list now instead of keeping the current song
            res = spotify_replace(argv[3:] if start else argv[2:], keep_current=not start)
        elif cmd == "tracks" and argv[2] == "subsonic":
            res = subsonic_tracks(argv[3])
        elif cmd == "spotify-login":
            return spotify_login(argv[2])
        else:
            sys.exit(__doc__)
        print(json.dumps({"__result": res, "__creds": UPDATED} if UPDATED else res))
    except Exception as e:  # the app shows this message on the Touch Bar
        out = {"error": str(e) or type(e).__name__}
        if UPDATED:
            out["__creds"] = UPDATED      # a token refreshed before the failure must still be saved
        print(json.dumps(out))
        sys.exit(1)


if __name__ == "__main__":
    import signal
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))   # so `finally` runs (an edit must not leave Spotify muted)
    main(sys.argv)
