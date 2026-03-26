#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

required_paths="
$ROOT_DIR/.env
$ROOT_DIR/.env.example
$ROOT_DIR/.gitattributes
$ROOT_DIR/.gitignore
$ROOT_DIR/.github
$ROOT_DIR/CONTRIBUTING.md
$ROOT_DIR/Dockerfile
$ROOT_DIR/LICENSE
$ROOT_DIR/NOTICE
$ROOT_DIR/README.md
$ROOT_DIR/SECURITY.md
$ROOT_DIR/compose.yaml
$ROOT_DIR/samples
$ROOT_DIR/scripts
$ROOT_DIR/scripts/check-runtime-tools.sh
"

missing=0

for path in $required_paths; do
  if [ ! -e "$path" ]; then
    printf 'missing: %s\n' "$path" >&2
    missing=1
  fi
done

if [ "$missing" -ne 0 ]; then
  exit 1
fi

if ! grep -q '^NUXEO_GIT_REF=[0-9a-f][0-9a-f]*$' "$ROOT_DIR/.env"; then
  printf '%s\n' "missing pinned NUXEO_GIT_REF in .env" >&2
  exit 1
fi

if grep -q 'Bootstrap only' "$ROOT_DIR/Dockerfile"; then
  printf '%s\n' "Dockerfile still contains the bootstrap placeholder" >&2
  exit 1
fi

printf '%s\n' "Bootstrap scaffold is present."
printf '%s\n' "Pinned public-source Docker build contract is present."
