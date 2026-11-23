#!/usr/bin/python3
"""Playlist providers for LyricsBar.

  library.py providers                  -> [{"id","name","ready"}]
  library.py playlists <provider>       -> [{"id","name","count"}]   (subsonic | spotify | applemusic)
  library.py tracks subsonic <id>       -> [{"id","title","artist","album","duration","stream","cover"}]
  library.py spotify-login <client_id>  -> one-time Spotify sign-in (opens the browser)
"""
import base64, hashlib, http.server, json, os, secrets, subprocess, sys, time
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
    t = http_json("https://accounts.spotify.com/api/token", data=body,
                  headers={"Content-Type": "application/x-www-form-urlencoded"})
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


def spotify_queue():
    tok = spotify_token()
    try:
        r = http_json("https://api.spotify.com/v1/me/player/queue", headers={"Authorization": f"Bearer {tok}"})
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"Spotify answered {e.code} (missing scope? reconnect)")
    out = []
    for t in r.get("queue", []):
        people = t.get("artists") or ([t["show"]] if t.get("show") else [])   # songs have artists, podcasts a show
        artists = ", ".join(a.get("name", "") for a in people)
        out.append({"title": t.get("name", "?"), "artist": artists})
    return out


def spotify_login(client_id):
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    auth = "https://accounts.spotify.com/authorize?" + urllib.parse.urlencode(dict(
        client_id=client_id, response_type="code", redirect_uri=REDIRECT, state=state,
        code_challenge_method="S256", code_challenge=challenge,
        scope="playlist-read-private playlist-read-collaborative user-library-read user-read-playback-state user-read-currently-playing"))
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
    main(sys.argv)
