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
# The .toc is the single source of truth, and this is deliberately the SAME
# expression as stamp-version.sh's toc_field -- keep the two identical. The
# version read here becomes the zip name and the release tag, while
# stamp-version.sh --check is what CI compares against main.lua, so two parsers
# that disagree about the same line ship a tag nothing verified: an earlier
# version took everything after the colon, which let a trailing space through
# into `v1.0.0 ` while --check compared the trimmed token and passed.
#
# The value is the first run of non-space characters, so anything after the
# number (a trailing space, an inline note) is dropped rather than carried. That
# also drops the CR from the CRLF endings a .toc edited on Windows will have --
# CR is whitespace to POSIX character classes -- so no separate tr is needed.
VERSION="$(sed -n 's/^## Version:[[:space:]]*\([^[:space:]][^[:space:]]*\).*$/\1/p' "$TOC" | head -1)"
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
# MIT terms; README.md is what a user reads after extracting; non-issues.md ships
# because shipped source cites it by relative path -- four times, across
# core/model.lua (x2), core/nativeHooks.lua and components/frameOptions.lua --
# and a dead pointer makes those dispositions unverifiable for anyone reading the
# source out of the zip.
EXTRAS=("$TOC" LICENSE README.md docs/non-issues.md)

# Whatever the shipped README embeds, so its images resolve offline from the
# extracted folder rather than needing a network round trip to GitHub. Derived
# from README.md rather than hardcoded for exactly the reason the code list is
# derived from the .toc: a hardcoded list silently ships a README with a broken
# image the first time a screenshot is added and the list is not updated.
# Restricted to docs/ so an absolute http(s) src is skipped rather than treated
# as a missing file.
readme_assets() {
  grep -o 'src="[^"]*"' README.md 2>/dev/null \
    | sed 's/^src="//; s/"$//' \
    | tr '\\' '/' \
    | grep '^docs/' || true
}

while IFS= read -r asset; do
  [ -n "$asset" ] && EXTRAS+=("$asset")
done < <(readme_assets)

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
