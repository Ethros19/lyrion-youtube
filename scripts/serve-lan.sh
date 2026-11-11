#!/usr/bin/env bash
# Serve the plugin to a Lyrion server on the local network without GitHub:
# builds a zip + repo.xml pointing at this machine and serves dist/ over HTTP.
# In Lyrion: Settings > Plugins > Additional repositories, add the printed URL.
set -euo pipefail
cd "$(dirname "$0")/.."
port=${PORT:-8765}
ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || hostname -I | awk '{print $1}')
BASE_URL="http://$ip:$port" REPO_XML=dist/repo.xml ./scripts/build.sh >/dev/null
echo "Repository URL for Lyrion: http://$ip:$port/repo.xml   (Ctrl-C to stop)"
cd dist && exec python3 -m http.server "$port"
