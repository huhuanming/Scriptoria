#!/bin/sh
PR_URL="$1"
REPO="$2"

if [ -z "$PR_URL" ]; then
  echo '{"decision":"needs_agent","reason":"sample: missing pr url"}'
  exit 0
fi

echo "{\"decision\":\"pass\",\"reason\":\"sample: checks green for ${REPO}\"}"
