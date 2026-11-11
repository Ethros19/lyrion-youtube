# YouTube Direct for Lyrion

Lyrion Music Server (LMS) plugin: YouTube audio with SponsorBlock skipping,
search, followed channels, playlists, links and chapters. Built for the
owner's LMS 9.0 server (x86_64 Red Hat, no shell access, can't upgrade), where
philippe44's YouTube plugin failed. Sibling of ~/Projects/KEXP and
~/Projects/Mixcloud (same conventions).

## Layout
- `src/YouTubeDirect/`: the plugin (installs as `Plugins/YouTubeDirect/`, prefix `Plugins::YouTubeDirect::`, prefs `plugin.youtubedirect`, menu tag `youtubedirect`, url scheme `ytdirect://<videoId>`)
  - `Plugin.pm`: OPML menus (Search folder: videos/channels/playlists/open link; Channels You Follow + "New from" feed; channel page; playlists; "More…" paging)
  - `ProtocolHandler.pm`: `getNextTrack` runs yt-dlp resolve + SponsorBlock in parallel, fetches the file head (ftyp/moov/sidx), stores fragments + skips in `pluginData(ytdirect)`. The handler is an `IO::Handle` with no socket (Mixcloud pattern): `sysread` serves a buffer filled by async per-fragment range GETs, fmp4 → ADTS, dropping samples inside skips; returns `EINTR` while waiting. 403 mid-stream → re-resolve (url expired) once a minute at most.
  - `YtDlp.pm`: locate/install (GitHub latest release asset for the platform into `<cachedir>/YouTubeDirect/`, LMS HTTP then curl/wget fallback), daily `yt-dlp -U`, async runs via `AnyEvent::Util::run_cmd` (Windows: Proc::Background + temp files), max 2 concurrent, 60 s timeout; `resolve` (`-f 140/139/... -O <fields>j`) and `list` (`--flat-playlist -J --playlist-items`)
  - `Source.pm`: menus' data layer; Data API when a key works, else yt-dlp; same item shapes either way; channel RSS for the followed feed; in-memory + cache of video metadata for now-playing
  - `API.pm`: Data API v3 client; key = own pref or philippe44's `plugin.youtube:APIkey`; suspends itself on 400 (bad key, 6 h) / 403 (quota, 1 h)
  - `SponsorBlock.pm`: `skipSegments` for all categories (cached 6 h), filtered by the `categories` pref; 404 = none; 5 s timeout, failure = no skips
  - `Util.pm`: pure helpers, unit tested (links, sidx/esds/trun parsing, ADTS, skip timeline, chapters, flat/RSS/API shapes, yt-dlp asset per platform)
  - `Settings.pm` + `HTML/EN/plugins/YouTubeDirect/settings/basic.html`: categories, yt-dlp status/update/auto/custom path, API key
- `tests/`: `prove tests/` (Util only; fixtures are Big Buck Bunny, CC-BY, plus trimmed real yt-dlp/RSS/SponsorBlock output)
- `scripts/dev-server.sh`: Docker LMS **9.0.0** on :9300 (`PLATFORM=linux/amd64` for x86_64 like the owner's box; `LMS_VERSION=`); log at `.dev/config/logs/server.log`; `docker restart youtube-lms` reloads code, then rerun `scripts/test-player.sh`
- `scripts/icon.py`: original mark (equaliser bars + skip chevron, teal tile; deliberately not YouTube's logo) + `MTL_icon_*` menu tiles. Needs `SSL_CERT_FILE=/etc/ssl/cert.pem` on python.org Python. Bump `NAME` (and install.xml) on art changes.
- `scripts/smoke.py`: weekly CI check of the YouTube/SponsorBlock facts below (bot-check on CI IPs = SKIPPED)

## YouTube facts (verified Nov 2026)
- Plain Perl can't get stream urls any more (JS challenges, PO tokens); yt-dlp is required. **A stale yt-dlp is the #1 failure**: philippe44's bundled 2025.11.12 got ANDROID-client urls that 403 after ~1 minute of audio. Current yt-dlp without a JS runtime picks the VISIONOS client: whole file fetchable. With deno present it picks TVHTML5, whose urls **require yt-dlp's `http_headers` User-Agent** (curl's UA → 403). Always send it.
- googlevideo refuses unranged GETs, open-ended ranges (`bytes=N-`) and ranges ≳ 1 MB (512 KB OK) on these urls → 403. One sidx fragment (40-162 KB, ≤ 10 s) per request.
- itag 140 = AAC-LC 44.1 kHz ~129 kbps fMP4: `ftyp`, `moov` (~700 B), one `sidx` (v0, timescale 44100, refs = fragments), then `moof`(tfhd 0x02002a default-base-is-moof, trun 0x201)+`mdat`. Head of 128 KB covers ~14 h of index.
- Stream urls are tied to the resolving IP and expire after hours: never cache them.
- Flat listings: `ytsearchN:q`; channel/playlist search via `results?search_query=…&sp=EgIQAg%253D%253D` / `EgIQAw%253D%253D`; `/channel/UC…/videos`, `/playlists` (exits 1 "does not have a playlists tab" → empty); uploads entries lack channel names (taken from the top level). Channel RSS `feeds/videos.xml?channel_id=` = latest 15, no key. oEmbed gives title/author for a pasted link.
- SponsorBlock: `GET /api/skipSegments?videoID=&categories=[…]&actionTypes=["skip"]` → array or 404. `music_offtopic` is the "non-music in music videos" category. Coverage varies; many DJ mixes have none.

## LMS 9.0 notes
- Bundled: AnyEvent::Util, Proc::Background, Digest::SHA1. Red Hat splits core Perl (no Devel::Peek, maybe no Digest::SHA): use only what LMS bundles.
- LMS's async HTTP error callback usually lacks the body: branch on the status in `$error` ("400 Bad Request").
- `Slim::Utils::Timers::killTimers($obj, $sub)` needs the same coderef.
- yt-dlp install from GitHub via LMS 9.0's HTTP worked in Docker (3 s); LyrionJS once failed on the owner's box with "Header line too long" from GitHub, hence the curl/wget fallback.
- Owner's box: plugin logging (`server.plugins`) is ERROR by default, so install warnings are invisible; a restart during a plugin download leaves a partial zip and LMS silently unticks the plugin.

## LMS gotchas (from KEXP/Mixcloud, still apply)
- Material: `MTL_icon_<name>` image paths get themed Material icons; search fields render as bare text boxes, so they live in the Search folder.
- Material only refreshes now-playing on push (`newmetadata`): `_scheduleTrackChange` wakes it at the next chapter boundary (capped 60 s), mapping video time ↔ the skip-adjusted timeline.
- Playable rows use the full favourite title as `name`, `line1`/`line2` for display. Don't give `link` items a `play` attribute.
- LMS addresses OPML entries by position and remotes show stale pages. `handleFeed` reads `$args->{params}{menu}` (only the top level is told; LMS rebuilds from there on every request) and every passthrough carries `menu`, so `channelMenu` serves two layouts: **menu mode (Material)**: Videos, Playlists, ONE toggle with no `type`/`image`, which Material treats as a clickable text row: runs in place (`doTextClick` → `browseHandleNextWindow`), toasts the reply, reloads the page (`nextWindow: refresh`). **Plain lists (LyrionJS's own look, CLI)**: Videos, Playlists, Follow (shows "✓ Following"; idempotent), Unfollow (only when following), all with icons, because LyrionJS keeps its old page on Back. `setFollow` ignores any request for the same channel within 2 s of the previous one: LyrionJS ≥0.2.33 re-asks every text reply in menu mode, which rebuilds the menu-mode page and would hit the toggle. The reply carries a `weblink`, else Material wraps a lone unclickable text item in `<div style=…>` and its toast shows that raw. "<Artist> - Topic" channels (no tabs, empty RSS) can't be followed. All verified with Playwright against Material 6.4.14 and LyrionJS 0.2.34 on LMS 9.0.0.
- Most CLI menu queries hang without a connected player: start the test player.

## No secrets
No credentials in the repo. The API key is a user setting on the server; never log it (API.pm logs endpoints without it). `.env` exists only by convention.
