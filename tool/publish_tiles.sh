#!/bin/sh
# Upload build/tiles to the rolling GitHub release "data".   Needs: gh (authenticated).
#   sh tool/publish_tiles.sh [owner/repo]
exec python3 "$(dirname "$0")/publish_tiles.py" "$@"
