#!/bin/sh

set -eu

if [ ! -f /.dockerenv ] && command -v docker >/dev/null 2>&1; then
  ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
  exec docker compose -f "$ROOT_DIR/compose.yaml" exec -T nuxeo /usr/local/bin/check-runtime-tools.sh
fi

required_commands="
soffice
pdftohtml
pdftotext
ffmpeg
ffprobe
convert
identify
gs
"

missing=0

for cmd in $required_commands; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'missing runtime command: %s\n' "$cmd" >&2
    missing=1
  fi
done

if [ "$missing" -ne 0 ]; then
  exit 1
fi

printf '%s\n' "Required runtime commands are available on PATH."
