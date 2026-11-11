#!/usr/bin/env bash
# Tiny JSON-RPC helper: scripts/lms.sh <player|-> '<json array>'   (LMS_HOST overrides the dev server)
p=$1; [ "$p" = - ] && p=""
curl -s -m 120 "${LMS_HOST:-localhost:9300}/jsonrpc.js" -d "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"$p\",$2]}"
