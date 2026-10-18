#!/bin/sh
# Upload build/tiles/* to the rolling GitHub release "data" and remove assets
# that are no longer part of the new manifest.   Needs: gh (authenticated).
#   sh tool/publish_tiles.sh [owner/repo]
set -e
REPO=${1:-sicpoe-wq/nearby-eats}
DIR=build/tiles
gh release view data -R "$REPO" >/dev/null 2>&1 || gh release create data -R "$REPO" --latest=false \
  --title "Overture data tiles (rolling)" --notes "Food & drink places from Overture Maps. See README."
ls $DIR | xargs -P 6 -I{} sh -c 'for i in 1 2 3; do gh release upload data '"$DIR"'/{} -R '"$REPO"' --clobber >/dev/null 2>&1 && exit 0; sleep 2; done; echo FAIL {}; exit 1'
# prune tiles that disappeared
gh release view data -R "$REPO" --json assets --jq '.assets[].name' | while read -r a; do
  [ -f "$DIR/$a" ] || { echo "removing stale $a"; gh release delete-asset data "$a" -R "$REPO" -y; }
done
echo "published $(ls $DIR | wc -l) files"
