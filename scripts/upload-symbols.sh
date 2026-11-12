#!/bin/bash
# Uploads the symbol tables of the app's dSYMs to Corlex, so crashes of release builds read as
# function, file and line. Meant for an Xcode "Run Script" build phase (see README.md):
#
#     "${BUILD_DIR%Build/*}SourcePackages/checkouts/<package folder>/scripts/upload-symbols.sh"
#
# Settings, from the environment (set them in the scheme, the project or CI; the token is a
# secret, keep it out of the repository):
#   CORLEX_UPLOAD_TOKEN   project upload token, corlex_up_…           (required)
#   CORLEX_API_URL        the Corlex API, e.g. https://api.corlex.ru (required)
#   CORLEX_PROJECT_ID     the project's id                            (required)
#   CORLEX_UPLOAD_SYMBOLS=0   turns the upload off
#   CORLEX_UPLOAD_DRY_RUN=1   generates the symbol tables and prints what would be sent
#   CORLEX_SYMTAB_DIR     keep the generated files here (default: a temporary folder)
#
# Xcode provides DWARF_DSYM_FOLDER_PATH. The script never fails the build: a missing token or
# an unreachable server is a warning.

warn() { echo "warning: Corlex: $*"; }
note() { echo "Corlex: $*"; }

if [ "${CORLEX_UPLOAD_SYMBOLS:-1}" = "0" ]; then note "symbol upload is off (CORLEX_UPLOAD_SYMBOLS=0)"; exit 0; fi

dsym_dir="${DWARF_DSYM_FOLDER_PATH:-}"
if [ -z "$dsym_dir" ] || ! ls -d "$dsym_dir"/*.dSYM >/dev/null 2>&1; then
  note "no dSYM was produced (a Debug build has none); nothing to upload"
  exit 0
fi

dry_run="${CORLEX_UPLOAD_DRY_RUN:-0}"
if [ "$dry_run" != "1" ]; then
  if [ -z "${CORLEX_UPLOAD_TOKEN:-}" ]; then warn "CORLEX_UPLOAD_TOKEN is not set; symbols are not uploaded, crashes stay unsymbolicated"; exit 0; fi
  if [ -z "${CORLEX_API_URL:-}" ] || [ -z "${CORLEX_PROJECT_ID:-}" ]; then warn "CORLEX_API_URL and CORLEX_PROJECT_ID are required; symbols are not uploaded"; exit 0; fi
fi

package_dir="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/corlex-symbols.XXXXXX")" || { warn "cannot create a temporary folder"; exit 0; }
trap 'rm -rf "$work_dir"' EXIT
out_dir="${CORLEX_SYMTAB_DIR:-$work_dir/symtab}"
tool="$work_dir/corlex-symtab"

# The build environment points the compiler at the iOS SDK; the generator is a Mac tool.
clean_env() { env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" DEVELOPER_DIR="${DEVELOPER_DIR:-}" TMPDIR="${TMPDIR:-/tmp}" "$@"; }

if ! clean_env xcrun --sdk macosx swiftc -O -o "$tool" "$package_dir"/Tools/Sources/corlex-symtab/*.swift >"$work_dir/compile.log" 2>&1; then
  warn "could not build the symbol table generator (see below); symbols are not uploaded"
  sed 's/^/  /' "$work_dir/compile.log" | head -20
  exit 0
fi

prefix_args=()
[ -n "${SRCROOT:-}" ] && prefix_args+=(--strip-prefix "$SRCROOT")
[ -n "${PROJECT_DIR:-}" ] && prefix_args+=(--strip-prefix "$PROJECT_DIR")

uploaded=0
failed=0
for dsym in "$dsym_dir"/*.dSYM; do
  [ -d "$dsym" ] || continue
  if ! tables="$(clean_env "$tool" "$dsym" --out "$out_dir" "${prefix_args[@]}" 2>"$work_dir/gen.log")"; then
    warn "could not read $(basename "$dsym"): $(head -1 "$work_dir/gen.log")"
    failed=$((failed + 1))
    continue
  fi
  while IFS=$'\t' read -r debug_id arch image file; do
    [ -n "$debug_id" ] || continue
    if [ "$dry_run" = "1" ]; then
      note "would upload $image ($arch) debug_id=$debug_id, $(wc -c <"$file" | tr -d ' ') bytes"
      continue
    fi
    gzip -c "$file" >"$file.gz"
    url="${CORLEX_API_URL%/}/api/projects/${CORLEX_PROJECT_ID}/symbols?platform=ios&kind=symtab&debug_id=${debug_id}"
    # The token goes to curl on stdin, not on the command line, where `ps` would show it.
    status="$(printf 'header = "Authorization: Bearer %s"\n' "$CORLEX_UPLOAD_TOKEN" |
      curl -sS -K - -X POST --max-time 120 -o "$work_dir/response" -w '%{http_code}' \
        -H 'Content-Type: application/json' -H 'Content-Encoding: gzip' \
        --data-binary @"$file.gz" "$url" 2>"$work_dir/curl.log")"
    case "$status" in
      201) note "uploaded $image ($arch) $debug_id"; uploaded=$((uploaded + 1)) ;;
      401) warn "the upload token was rejected (401) for $image"; failed=$((failed + 1)) ;;
      404) warn "project not found or no access (404): check CORLEX_PROJECT_ID"; failed=$((failed + 1)) ;;
      413) warn "$image is too big for the server (413)"; failed=$((failed + 1)) ;;
      000) warn "could not reach $CORLEX_API_URL: $(head -1 "$work_dir/curl.log")"; failed=$((failed + 1)) ;;
      *)   warn "upload of $image failed with HTTP $status"; failed=$((failed + 1)) ;;
    esac
  done <<<"$tables"
done

[ "$dry_run" = "1" ] || note "$uploaded symbol table(s) uploaded, $failed failed"
exit 0
