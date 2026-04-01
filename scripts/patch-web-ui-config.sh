#!/bin/sh

set -eu

NUXEO_HOME="${NUXEO_HOME:-/opt/nuxeo/server}"
UI_DIR="${NUXEO_HOME}/nxserver/nuxeo.war/ui"
BUNDLE_FILE="${UI_DIR}/nuxeo-web-ui-bundle.html"
CUSTOM_BUNDLE_FILE="${UI_DIR}/nuxeo-custom-bundle.html"
IMPORT_LINE='<link rel="import" href="nuxeo-custom-bundle.html">'

if [ ! -f "$BUNDLE_FILE" ]; then
  printf 'missing Web UI bundle: %s\n' "$BUNDLE_FILE" >&2
  exit 1
fi

if [ ! -f "$CUSTOM_BUNDLE_FILE" ]; then
  printf 'missing custom Web UI bundle: %s\n' "$CUSTOM_BUNDLE_FILE" >&2
  exit 1
fi

if grep -Fq "$IMPORT_LINE" "$BUNDLE_FILE"; then
  printf '%s\n' "Web UI bundle already imports nuxeo-custom-bundle.html"
  exit 0
fi

printf '\n%s\n' "$IMPORT_LINE" >> "$BUNDLE_FILE"
printf '%s\n' "Patched nuxeo-web-ui-bundle.html with Content Lake custom bundle"
