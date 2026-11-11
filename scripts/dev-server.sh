#!/usr/bin/env bash
# Throwaway Lyrion 9.0.0 (what the owner's server runs; the oldest version
# we target) in Docker with this plugin mounted live. Web UI: http://localhost:9300
# Restart the container to reload Perl code: docker restart youtube-lms
# Other versions: LMS_VERSION=9.2.0, or LMS_IMAGE=lmscommunity/logitechmediaserver LMS_VERSION=8.5.2
# x86_64 like the owner's box (slower, emulated): PLATFORM=linux/amd64
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .dev/config
docker rm -f youtube-lms >/dev/null 2>&1 || true
docker run -d --name youtube-lms ${PLATFORM:+--platform "$PLATFORM"} \
  -p 9300:9000 -p 9390:9090 \
  -v "$PWD/.dev/config:/config" \
  -v "$PWD/src/YouTubeDirect:/config/cache/Plugins/YouTubeDirect:ro" \
  -e EXTRA_ARGS="--debug plugin.youtubedirect=INFO" \
  "${LMS_IMAGE:-lmscommunity/lyrionmusicserver}:${LMS_VERSION:-9.0.0}"
echo "Lyrion starting on http://localhost:9300 (logs: .dev/config/logs/server.log)"
