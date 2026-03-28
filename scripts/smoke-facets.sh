#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMPOSE_FILE=$ROOT_DIR/compose.yaml
SERVICE=nuxeo
NAMESPACE=codex-facets-$(date +%Y%m%d%H%M%S)

run_in_nuxeo() {
  docker compose -f "$COMPOSE_FILE" exec -T "$SERVICE" bash -lc "$1"
}

extract_json_field() {
  field_name=$1
  printf '%s' "$2" | tr -d '\n' | sed -n "s/.*\"$field_name\":\"\\([^\"]*\\)\".*/\\1/p"
}

printf '%s\n' "Running facets smoke test against $SERVICE..."

# 1. Create a Workspace folder to annotate
create_payload=$(cat <<EOF
{"params":{"type":"Workspace","name":"$NAMESPACE","properties":"dc:title=Content Lake Facets Smoke"},"input":"doc:/default-domain/workspaces"}
EOF
)
create_result=$(run_in_nuxeo "wget --content-on-error -qO- --user Administrator --password Administrator --header=\"Content-Type: application/json\" --post-data='$create_payload' http://127.0.0.1:8080/nuxeo/site/automation/Document.Create")
folder_uid=$(extract_json_field "uid" "$create_result")

if [ -z "$folder_uid" ]; then
  printf '%s\n' "Failed to create smoke-test folder." >&2
  printf '%s\n' "$create_result" >&2
  exit 1
fi
printf '  %s\n' "Created folder uid: $folder_uid"

# 2. Apply ContentLakeIndexed facet via PUT /api/v1/id/{uid}
indexed_put_body='{"entity-type":"document","facets":["ContentLakeIndexed"]}'
indexed_put_result=$(run_in_nuxeo "curl -sS -X PUT -u Administrator:Administrator -H 'Content-Type: application/json' -d '$indexed_put_body' http://127.0.0.1:8080/nuxeo/api/v1/id/$folder_uid")

# 3. GET and verify ContentLakeIndexed in facets array
get_result=$(run_in_nuxeo "curl -sS -u Administrator:Administrator http://127.0.0.1:8080/nuxeo/api/v1/id/$folder_uid")
indexed_present=$(printf '%s' "$get_result" | grep -c '"ContentLakeIndexed"' || true)
if [ "$indexed_present" -lt 1 ]; then
  printf '%s\n' "ContentLakeIndexed facet was not found in the document response." >&2
  printf '%s\n' "$get_result" >&2
  exit 1
fi
printf '  %s\n' "ContentLakeIndexed facet verified OK"

# 4. Apply ContentLakeScope facet with cls:excludeFromScope = true
scope_put_body='{"entity-type":"document","facets":["ContentLakeIndexed","ContentLakeScope"],"properties":{"cls:excludeFromScope":true}}'
scope_put_result=$(run_in_nuxeo "curl -sS -X PUT -u Administrator:Administrator -H 'Content-Type: application/json' -d '$scope_put_body' http://127.0.0.1:8080/nuxeo/api/v1/id/$folder_uid")

# 5. GET and verify ContentLakeScope in facets and cls:excludeFromScope in properties
get_result2=$(run_in_nuxeo "curl -sS -u Administrator:Administrator -H 'X-NXDocumentProperties: *' http://127.0.0.1:8080/nuxeo/api/v1/id/$folder_uid")
scope_present=$(printf '%s' "$get_result2" | grep -c '"ContentLakeScope"' || true)
exclude_present=$(printf '%s' "$get_result2" | grep -c '"cls:excludeFromScope":true' || true)

if [ "$scope_present" -lt 1 ]; then
  printf '%s\n' "ContentLakeScope facet was not found in the document response." >&2
  printf '%s\n' "$get_result2" >&2
  exit 1
fi
if [ "$exclude_present" -lt 1 ]; then
  printf '%s\n' "cls:excludeFromScope was not set to true in the document properties." >&2
  printf '%s\n' "$get_result2" >&2
  exit 1
fi
printf '  %s\n' "ContentLakeScope facet and cls:excludeFromScope=true verified OK"

# 6. Clean up — trash the test folder
trash_payload=$(cat <<EOF
{"params":{},"input":"doc:$folder_uid"}
EOF
)
run_in_nuxeo "wget --content-on-error -qO- --user Administrator --password Administrator --header=\"Content-Type: application/json\" --post-data='$trash_payload' http://127.0.0.1:8080/nuxeo/site/automation/Document.Trash" > /dev/null

printf '%s\n' "Facets smoke test passed."
