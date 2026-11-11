# YouTube Direct for Lyrion

A [Lyrion Music Server](https://lyrion.org) plugin that plays YouTube audio, with
**[SponsorBlock](https://sponsor.ajay.app)**: sponsor reads, self-promotion and
the non-music parts of music videos are cut out of the audio as you listen.

- **Search** videos, channels and playlists, or **open a pasted link** (videos,
  `youtu.be`, Shorts, playlists, channels, `@handles`)
- **Follow channels in Lyrion** (kept on your server only) and get a merged
  "New from channels you follow" feed
- **Favorites**: ♥ any video from its More menu (⋮ → More, or Now Playing →
  More); see them all under Favorites, or one channel's on its page
- **Chapters as now-playing**: a DJ mix with a timestamped tracklist shows the
  track that's playing, like Mixcloud tracklists
- **Seek anywhere**, including in long mixes
- **No shell access needed**: it downloads its own copy of
  [yt-dlp](https://github.com/yt-dlp/yt-dlp) into Lyrion's cache folder and
  updates it daily, so it keeps working when YouTube changes things
- **Small download**: the plugin zip is about 2 MB (yt-dlp is fetched on first
  use, only the build for your machine, instead of bundling every platform)
- **API key optional**: without one, search and browsing go through yt-dlp

Built for Lyrion 9.0 servers that can't be upgraded; it targets Lyrion 8.0 and
newer. Tested on 9.0.0 (ARM64 and x86_64).

## Install

In Lyrion: **Settings → Manage Plugins**, add this repository URL at the bottom
under *Additional repositories*, then tick **YouTube Direct**:

```
https://raw.githubusercontent.com/Ethros19/lyrion-youtube/main/repo.xml
```

Let the download finish before restarting (the page offers a restart right away;
the zip is small, so a few seconds is enough).

It appears under **My Apps → YouTube Direct**. The first video you play (or the
*Install yt-dlp now* button in the plugin's settings) downloads yt-dlp
(about 35-40 MB).

## How skipping works

YouTube's own ads never reach this plugin: yt-dlp fetches the video's audio
directly. What SponsorBlock covers is the stuff *inside* videos. When you press
play, the plugin looks up the video's segments, and the stream simply leaves
them out: those frames are dropped (whole fragments aren't even downloaded).
The elapsed time and duration skip with them, so the progress bar matches what
you hear, and seeking and chapters still line up.

Pick which kinds to skip on the settings page. On by default: sponsor,
self-promotion, interaction reminders, and **non-music** (talking in music
videos and mixes). Intro, outro, previews and filler are off by default.

SponsorBlock is crowd-sourced, so only videos someone has marked up have
segments. Popular sponsored videos usually do; many DJ mixes don't.

## Settings

- **Skip with SponsorBlock**: which segment categories to cut
- **yt-dlp**: installed version, *Update now*, daily auto-update (on by default)
- **YouTube Data API key** (optional): faster search and browsing, limited to
  ~100 searches a day. Free from Google Cloud Console (enable *YouTube Data
  API v3*, create an API key). If you already entered a key in the *YouTube*
  plugin, it's used automatically. If the key stops working the plugin falls
  back to yt-dlp.
- **Custom yt-dlp**: use a yt-dlp the server already has (you keep it updated)

## Limits

- No live streams or premieres yet
- No age-restricted, private or members-only videos (no YouTube login, ever)
- YouTube occasionally asks servers to "confirm you're not a bot"; updating
  yt-dlp usually fixes it
- Windows support is untested

## Privacy

No YouTube login. Channels you follow are stored on your Lyrion server only.
Video ids are sent to SponsorBlock (sponsor.ajay.app) to look up segments.
Favorites are kept on your Lyrion server only, separate from Lyrion's own
Favorites.

## How it works

At play time yt-dlp turns the video id into a short-lived URL for its AAC audio
(itag 140). That file is fragmented MP4 with an index (`sidx`) of every
~10-second fragment. The plugin fetches the index, then one fragment per
request (YouTube refuses ranges much over 512 KB), converts each to ADTS AAC and
streams that to the player. yt-dlp runs for a couple of seconds and exits;
nothing long-running is left on the server.

## Development

```
prove tests/                       # unit tests (Util.pm, against real stream data)
scripts/dev-server.sh              # LMS 9.0.0 in Docker on :9300, plugin mounted live
scripts/test-player.sh             # headless squeezelite attached to it
scripts/lms.sh <player> '<json>'   # JSON-RPC helper
scripts/smoke.py                   # live checks of YouTube/SponsorBlock behaviour
scripts/build.sh                   # dist/YouTubeDirect-<version>.zip + repo.xml
scripts/serve-lan.sh               # serve a build to a Lyrion box on your LAN
```

Test fixtures use *Big Buck Bunny* (© Blender Foundation, CC-BY 3.0).

## License

GPL-2.0 (see LICENSE). Not affiliated with YouTube or Google.
