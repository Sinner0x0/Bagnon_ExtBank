#!/usr/bin/env bash
#
# Builds the installable addon zip into dist/.
#
# The repo root IS the addon folder, so the zip cannot just be an archive of the
# checkout: it has to contain exactly one top-level directory named
# `Bagnon_ExtBank`, or extracting it into Interface\AddOns produces a folder
# under the wrong name and the addon never loads. That is what the staging copy
# below is for.
#
# The shipped file list is DERIVED from the .toc, following <Script>/<Include>
# references through the XMLs, rather than hardcoded. A hardcoded list silently
# ships a broken addon the first time a file is added and the list is not
# updated.
#
# Run locally the same way CI does:  bash .github/scripts/build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

ADDON="Bagnon_ExtBank"
TOC="$ADDON.toc"

# --- version ----------------------------------------------------------------
# The .toc is the single source of truth. tr strips the CR from CRLF endings,
# which .toc files edited on Windows will have.
VERSION="$(grep -m1 '^## Version:' "$TOC" | sed 's/^## Version:[[:space:]]*//' | tr -d '\r')"
[ -n "$VERSION" ] || { echo "::error::could not read '## Version:' from $TOC"; exit 1; }

# --- work out what ships ----------------------------------------------------
# Extract every file="..." reference from a WoW XML (Script and Include alike).
# Paths inside an XML are relative to that XML's own directory, and use
# backslashes. Deliberately not grep -oP: -P is absent from BSD/macOS grep.
xml_refs() {
  local xml="$1" dir
  dir="$(dirname "$xml")"
  grep -o 'file="[^"]*"' "$xml" 2>/dev/null \
    | sed 's/^file="//; s/"$//' \
    | tr '\\' '/' \
    | while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        if [ "$dir" = "." ]; then printf '%s\n' "$ref"; else printf '%s/%s\n' "$dir" "$ref"; fi
      done
}

declare -A SEEN=()
FILES=()
QUEUE=()

# Seed the queue with the .toc's own entries: every non-comment, non-blank line.
while IFS= read -r line; do
  QUEUE+=("$line")
done < <(tr -d '\r' < "$TOC" | sed 's/[[:space:]]*$//' | grep -v '^#' | grep -v '^$' | tr '\\' '/')

while [ ${#QUEUE[@]} -gt 0 ]; do
  f="${QUEUE[0]}"
  QUEUE=("${QUEUE[@]:1}")

  [ -z "${SEEN[$f]:-}" ] || continue
  SEEN["$f"]=1

  if [ ! -f "$f" ]; then
    echo "::error::referenced by the .toc or an XML but not found on disk: $f"
    exit 1
  fi
  FILES+=("$f")

  # Follow XML references so nested includes are picked up too.
  case "$f" in
    *.xml|*.XML)
      while IFS= read -r ref; do
        [ -n "$ref" ] && QUEUE+=("$ref")
      done < <(xml_refs "$f")
      ;;
  esac
done

# Files that ship but are not referenced by the .toc. LICENSE is required by the
# MIT terms; README.md is what a user reads after extracting.
EXTRAS=("$TOC" LICENSE README.md)

# --- stage and zip ----------------------------------------------------------
rm -rf build dist
mkdir -p "build/$ADDON" dist

for f in "${EXTRAS[@]}" "${FILES[@]}"; do
  [ -f "$f" ] || { echo "::error::missing file: $f"; exit 1; }
  mkdir -p "build/$ADDON/$(dirname "$f")"
  cp "$f" "build/$ADDON/$f"
done

( cd build && zip -qr "../dist/$ADDON-$VERSION.zip" "$ADDON" )

echo "shipped ${#FILES[@]} referenced files + ${#EXTRAS[@]} extras:"
printf '  %s\n' "${EXTRAS[@]}" "${FILES[@]}"

# Let the calling workflow reuse these instead of re-parsing the .toc itself.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "version=$VERSION"
    echo "zip=dist/$ADDON-$VERSION.zip"
  } >> "$GITHUB_OUTPUT"
fi

echo "built dist/$ADDON-$VERSION.zip"
