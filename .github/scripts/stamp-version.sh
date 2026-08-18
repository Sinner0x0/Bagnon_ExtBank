#!/usr/bin/env bash
#
# Keeps the version and date identical in the two places they have to live:
#
#   Bagnon_ExtBank.toc   ## Version: / ## X-Date:
#                        What addon managers list, and what build.sh and
#                        release.yml read to name and tag a release.
#
#   main.lua             ExtBank.VERSION / ExtBank.DATE
#                        What the options panel prints. It can't use the .toc
#                        values: the client parses .toc files once at launch
#                        and caches them, so after a drop-in update and a
#                        /reload the panel would still show the old build.
#                        See main.lua's Identity block.
#
# `## Version:` in the .toc stays the single source of truth for the version --
# bumping it there is still the one thing that publishes a release. This script
# never invents a version; it only mirrors that one into main.lua, and stamps
# today's date into both files.
#
#   bash .github/scripts/stamp-version.sh           stamp (what pre-commit runs)
#   bash .github/scripts/stamp-version.sh --check   verify only, writes nothing
#
# --check compares the two files against EACH OTHER, never against today's
# date -- CI must not fail a pull request merely for being merged on a later
# day than it was pushed. Only stamping looks at the clock.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

TOC="Bagnon_ExtBank.toc"
MAIN="main.lua"

# Read one "## Field: value" out of the .toc. The value is taken as the first
# run of non-space characters, which also drops the CR that .toc lines edited
# on Windows carry -- CR is whitespace to POSIX character classes.
toc_field() {
  sed -n "s/^## $1:[[:space:]]*\([^[:space:]][^[:space:]]*\).*\$/\1/p" "$TOC" | head -1
}

# Read one ExtBank.FIELD = '...' constant out of main.lua. Only the text
# between the quotes is captured, so CRLF endings are irrelevant here too.
lua_field() {
  sed -n "s/^ExtBank\\.$1[[:space:]]*=[[:space:]]*'\\([^']*\\)'.*\$/\1/p" "$MAIN" | head -1
}

# Rewrite in place without sed -i, which needs an argument on BSD/macOS and
# none on GNU. Writing back through `cat >` rather than `mv` keeps the original
# file's permissions, and works when TMPDIR is on another volume (Windows).
#
# Note for Windows: Git for Windows builds sed (and awk) in text mode, so a
# pass through either one rewrites a CRLF file as LF whether you asked it to or
# not -- these two files come out LF-only after a stamp. Nothing downstream
# cares. git has core.autocrlf on here and normalises to LF when staging, so
# the commit is byte-identical either way (and `git diff` stays empty), and the
# 3.3.5 client reads .toc and .lua files with either ending. Not worth the
# line-by-line rewrite in bash it would take to put the CRs back.
apply() {
  local file="$1" expr="$2" tmp
  tmp="$(mktemp)"
  sed "$expr" "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

VERSION="$(toc_field Version)"
[ -n "$VERSION" ] || { echo "::error::could not read '## Version:' from $TOC"; exit 1; }

case "${1:-}" in
  --check)
    TOC_DATE="$(toc_field X-Date)"
    LUA_VERSION="$(lua_field VERSION)"
    LUA_DATE="$(lua_field DATE)"

    [ -n "$TOC_DATE" ]    || { echo "::error::could not read '## X-Date:' from $TOC"; exit 1; }
    [ -n "$LUA_VERSION" ] || { echo "::error::could not read ExtBank.VERSION from $MAIN"; exit 1; }
    [ -n "$LUA_DATE" ]    || { echo "::error::could not read ExtBank.DATE from $MAIN"; exit 1; }

    drift=0
    if [ "$LUA_VERSION" != "$VERSION" ]; then
      echo "::error::version drift: $TOC has $VERSION, $MAIN has $LUA_VERSION"
      drift=1
    fi
    if [ "$LUA_DATE" != "$TOC_DATE" ]; then
      echo "::error::date drift: $TOC has $TOC_DATE, $MAIN has $LUA_DATE"
      drift=1
    fi

    if [ "$drift" -ne 0 ]; then
      echo "the options panel would print something the .toc disagrees with."
      echo "fix both with:  bash .github/scripts/stamp-version.sh"
      echo "then commit $TOC and $MAIN."
      exit 1
    fi

    echo "in sync: v$VERSION -- $TOC_DATE"
    ;;

  '')
    # DD-MM-YYYY, the format the panel has always printed.
    DATE="$(date +%d-%m-%Y)"

    BEFORE="$(toc_field X-Date) $(lua_field VERSION) $(lua_field DATE)"

    apply "$TOC"  "s/^\\(## X-Date:[[:space:]]*\\)[^[:space:]]*/\\1$DATE/"
    apply "$MAIN" "s/^\\(ExtBank\\.VERSION[[:space:]]*=[[:space:]]*'\\)[^']*\\('\\)/\\1$VERSION\\2/"
    apply "$MAIN" "s/^\\(ExtBank\\.DATE[[:space:]]*=[[:space:]]*'\\)[^']*\\('\\)/\\1$DATE\\2/"

    AFTER="$(toc_field X-Date) $(lua_field VERSION) $(lua_field DATE)"

    # Confirm the substitutions actually matched, rather than trusting sed's
    # exit code -- sed is perfectly happy to match nothing and report success,
    # which is exactly what would happen if either constant were renamed.
    if [ "$(lua_field VERSION)" != "$VERSION" ] || [ "$(lua_field DATE)" != "$DATE" ] \
       || [ "$(toc_field X-Date)" != "$DATE" ]; then
      echo "::error::stamp did not take -- has a field been renamed in $TOC or $MAIN?"
      exit 1
    fi

    if [ "$BEFORE" = "$AFTER" ]; then
      echo "already stamped: v$VERSION -- $DATE"
    else
      echo "stamped: v$VERSION -- $DATE  ($TOC, $MAIN)"
    fi
    ;;

  *)
    echo "usage: $0 [--check]" >&2
    exit 2
    ;;
esac