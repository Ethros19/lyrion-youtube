#!/usr/bin/env python3
"""Check that YouTube and SponsorBlock still behave the way the plugin assumes.

Run weekly in CI and before releases (locally on python.org Python:
SSL_CERT_FILE=/etc/ssl/cert.pem). Needs yt-dlp on PATH (CI installs it).

YouTube sometimes asks datacenter IPs (like CI runners) to "confirm you're
not a bot"; that's reported as SKIPPED rather than a failure, since it says
nothing about the plugin.
"""

import json
import struct
import subprocess
import sys
import urllib.request

VIDEO = "aqz-KE-bpKQ"          # Big Buck Bunny (CC-BY, Blender): has an outro segment
CHANNEL = "UCSMOQeBJ2RAnuFungnQOxLg"   # Blender
MAX_RANGE = 524288
failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + (f": {detail}" if detail else ""))
    if not ok:
        failures.append(name)


def get(url, headers=None, rng=None):
    req = urllib.request.Request(url, headers=dict(headers or {}))
    if rng:
        req.add_header("Range", f"bytes={rng[0]}-{rng[1]}")
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.status, r.read()


def ytdlp(*args):
    p = subprocess.run(["yt-dlp", "--no-update", "--ignore-config", "--no-warnings", *args],
                       capture_output=True, text=True, timeout=120)
    if "confirm you" in p.stderr and "bot" in p.stderr:
        print("SKIPPED YouTube checks: YouTube is bot-checking this IP")
        return None
    return p


def boxes(buf):
    pos, out = 0, []
    while pos + 8 <= len(buf):
        size, kind = struct.unpack(">I4s", buf[pos:pos + 8])
        out.append((kind.decode("latin1"), pos, size))
        if size < 8:
            break
        pos += size
    return out


def sidx_fragments(buf, start):
    version = buf[start + 8]
    timescale = struct.unpack(">I", buf[start + 16:start + 20])[0]
    q = start + 20 + (8 if version == 0 else 16)
    count = struct.unpack(">H", buf[q + 2:q + 4])[0]
    q += 4
    refs = [struct.unpack(">III", buf[q + i * 12:q + i * 12 + 12]) for i in range(count)]
    return [r[0] & 0x7FFFFFFF for r in refs], timescale


def youtube():
    p = ytdlp("-f", "140", "-O", "%(.{url,http_headers,duration,chapters})j", "--", f"https://www.youtube.com/watch?v={VIDEO}")
    if p is None:
        return
    check("yt-dlp resolves itag 140", p.returncode == 0 and p.stdout.strip().startswith("{"), p.stderr.strip()[-200:])
    if p.returncode:
        return
    info = json.loads(p.stdout.strip().splitlines()[-1])
    ua = {"User-Agent": info["http_headers"]["User-Agent"]}

    status, head = get(info["url"], ua, (0, 131071))
    kinds = [b[0] for b in boxes(head)][:3]
    check("head is ftyp/moov/sidx", kinds == ["ftyp", "moov", "sidx"], str(kinds))
    sidx = next(b for b in boxes(head) if b[0] == "sidx")
    sizes, _ = sidx_fragments(head, sidx[1])
    check("every fragment fits one range", max(sizes) <= MAX_RANGE, f"largest {max(sizes)}")

    deep = sidx[1] + sidx[2] + sum(sizes[:-1])
    try:
        status, _ = get(info["url"], ua, (deep, deep + sizes[-1] - 1))
        check("last fragment is fetchable", status == 206, str(status))
    except Exception as e:
        check("last fragment is fetchable", False, str(e))

    p = ytdlp("--flat-playlist", "-J", "--playlist-items", "1-3", "ytsearch3:blender open movie")
    if p is not None:
        ok = p.returncode == 0 and len(json.loads(p.stdout or "{}").get("entries") or []) > 0
        check("flat search", ok, p.stderr.strip()[-200:])


def sponsorblock():
    try:
        status, body = get(f"https://sponsor.ajay.app/api/skipSegments?videoID={VIDEO}&categories=%5B%22outro%22%5D")
        data = json.loads(body)
        ok = isinstance(data, list) and all(isinstance(s.get("segment"), list) for s in data)
        check("SponsorBlock segments", ok and len(data) > 0, f"{len(data)} segment(s)")
    except Exception as e:
        check("SponsorBlock segments", False, str(e))


def rss():
    try:
        status, body = get(f"https://www.youtube.com/feeds/videos.xml?channel_id={CHANNEL}")
        check("channel RSS feed", status == 200 and body.count(b"<yt:videoId>") > 0, f"{body.count(b'<entry>')} entries")
    except Exception as e:
        check("channel RSS feed", False, str(e))


def oembed():
    try:
        status, body = get(f"https://www.youtube.com/oembed?format=json&url=https://www.youtube.com/watch?v={VIDEO}")
        check("oEmbed title", bool(json.loads(body).get("title")))
    except Exception as e:
        check("oEmbed title", False, str(e))


youtube()
sponsorblock()
rss()
oembed()
sys.exit(1 if failures else 0)
