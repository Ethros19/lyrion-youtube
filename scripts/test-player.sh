#!/usr/bin/env bash
# Headless squeezelite "TestPlayer" (00:11:22:33:44:88) attached to the dev
# server for CLI testing. Audio goes to /dev/null, so it plays faster than
# real time. Restart it after restarting youtube-lms (they share a network).
set -euo pipefail
docker rm -f youtube-player >/dev/null 2>&1 || true
# Verify-Peer=false: slim image has no CA bundle yet; apt still checks package signatures
docker run -d --name youtube-player --network container:youtube-lms debian:trixie-slim sh -c '
  sed -i s#http://#https://#g /etc/apt/sources.list.d/debian.sources
  A="-o Acquire::https::Verify-Peer=false"
  apt-get $A update -qq && DEBIAN_FRONTEND=noninteractive apt-get $A install -y -qq squeezelite >/dev/null
  exec squeezelite -n TestPlayer -m 00:11:22:33:44:88 -s 127.0.0.1 -o - > /dev/null'
echo "TestPlayer starting; try: scripts/lms.sh 00:11:22:33:44:88 '[\"youtubedirect\",\"items\",0,10]'"
