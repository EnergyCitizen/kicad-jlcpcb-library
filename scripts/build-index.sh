#!/usr/bin/env bash
#
# Builds the KiCad PCM index (repository.json + packages.json + resources.zip)
# from the latest N releases of CDFER/JLCPCB-Kicad-Library.
#
# Each upstream release ZIP is already a valid KiCad PCM package
# (root metadata.json + symbols/ footprints/ 3dmodels/ resources/icon.png),
# so this script only computes the per-version download_sha256 / download_size /
# install_size and emits the repository index that KiCad's Plugin & Content
# Manager consumes.
#
# Requires: gh, jq, curl, unzip, sha256sum, zip
set -euo pipefail

UPSTREAM="${UPSTREAM:-CDFER/JLCPCB-Kicad-Library}"
KEEP="${KEEP:-30}"                       # number of recent versions to expose
BASE="${BASE:-https://raw.githubusercontent.com/EnergyCitizen/kicad-jlcpcb-library/main}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$ROOT/.build"

mkdir -p "$B/zips" "$B/res"
cd "$ROOT"

echo "==> Fetching latest $KEEP releases of $UPSTREAM"
gh api "repos/$UPSTREAM/releases?per_page=$KEEP" \
  | jq '[.[] | select(.assets|length>0)
         | {tag:.tag_name, asset:.assets[0].name, url:.assets[0].browser_download_url}]' \
  > "$B/releases.json"
n=$(jq length "$B/releases.json")
echo "    $n releases"

: > "$B/versions.ndjson"
for i in $(seq 0 $((n-1))); do
  tag=$(jq -r ".[$i].tag"   "$B/releases.json")
  name=$(jq -r ".[$i].asset" "$B/releases.json")
  url=$(jq -r ".[$i].url"    "$B/releases.json")
  f="$B/zips/$name"
  if [ ! -s "$f" ]; then
    echo "==> Download $name"
    curl -fsSL "$url" -o "$f"
  fi
  sha=$(sha256sum "$f" | awk '{print $1}')
  dsize=$(wc -c < "$f" | tr -d ' ')
  isize=$(unzip -l "$f" | tail -1 | awk '{print $1}')
  kv=$(unzip -p "$f" metadata.json | jq -r '.versions[0].kicad_version')
  st=$(unzip -p "$f" metadata.json | jq -r '.versions[0].status')
  jq -nc --arg v "$tag" --arg s "$st" --arg kv "$kv" --arg sha "$sha" \
     --argjson ds "$dsize" --argjson is "$isize" --arg url "$url" \
     '{version:$v,status:$s,kicad_version:$kv,download_sha256:$sha,
       download_size:$ds,install_size:$is,download_url:$url}' >> "$B/versions.ndjson"
done

echo "==> Building packages.json"
LATEST=$(jq -r '.[0].asset' "$B/releases.json")
unzip -p "$B/zips/$LATEST" metadata.json \
  | jq --slurpfile vs <(jq -s '.' "$B/versions.ndjson") \
      '{name,description,description_full,identifier,type,author,license,resources,tags,
        versions:$vs[0]}' > "$B/pkg_entry.json"
jq -n --slurpfile p "$B/pkg_entry.json" \
  '{"$schema":"https://go.kicad.org/pcm/schemas/v1","packages":[$p[0]]}' > packages.json

echo "==> Building resources.zip"
ID=$(jq -r '.packages[0].identifier' packages.json)
rm -rf "$B/res/$ID"; mkdir -p "$B/res/$ID"
unzip -p "$B/zips/$LATEST" resources/icon.png > "$B/res/$ID/icon.png"
rm -f resources.zip
( cd "$B/res" && zip -qr "$ROOT/resources.zip" "$ID" )

echo "==> Building repository.json"
PKG_SHA=$(sha256sum packages.json | awk '{print $1}')
RES_SHA=$(sha256sum resources.zip | awk '{print $1}')
TS=$(date +%s); UTC=$(date -u +"%Y-%m-%d %H:%M:%S")
jq -n --arg base "$BASE" --arg psha "$PKG_SHA" --arg rsha "$RES_SHA" \
  --argjson ts "$TS" --arg utc "$UTC" '
  {"$schema":"https://go.kicad.org/pcm/schemas/v1#/definitions/Repository",
   maintainer:{name:"EnergyCitizen",
               contact:{web:"https://github.com/EnergyCitizen/kicad-jlcpcb-library"}},
   name:"EnergyCitizen JLCPCB KiCad Library (auto-mirror of CDFER releases)",
   packages:{url:($base+"/packages.json"),sha256:$psha,update_timestamp:$ts,update_time_utc:$utc},
   resources:{url:($base+"/resources.zip"),sha256:$rsha,update_timestamp:$ts,update_time_utc:$utc}}
  ' > repository.json

echo "==> Done: $(jq '.packages[0].versions|length' packages.json) versions"
