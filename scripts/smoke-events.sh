#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMPOSE_FILE=$ROOT_DIR/compose.yaml
SERVICE=nuxeo
NAMESPACE=codex-audit-$(date +%Y%m%d%H%M%S)

run_in_nuxeo() {
  docker compose -f "$COMPOSE_FILE" exec -T "$SERVICE" bash -lc "$1"
}

extract_json_field() {
  field_name=$1
  printf '%s' "$2" | tr -d '\n' | sed -n "s/.*\"$field_name\":\"\\([^\"]*\\)\".*/\\1/p"
}

printf '%s\n' "Running event smoke test against $SERVICE..."

create_payload=$(cat <<EOF
{"params":{"type":"Note","name":"$NAMESPACE","properties":"dc:title=Codex Audit Smoke\\nnote:note=initial event body"},"input":"doc:/default-domain/workspaces"}
EOF
)

create_result=$(run_in_nuxeo "wget --content-on-error -qO- --user Administrator --password Administrator --header=\"Content-Type: application/json\" --post-data='$create_payload' http://127.0.0.1:8080/nuxeo/site/automation/Document.Create")
doc_uid=$(extract_json_field "uid" "$create_result")
doc_path=$(extract_json_field "path" "$create_result")

if [ -z "$doc_uid" ] || [ -z "$doc_path" ]; then
  printf '%s\n' "Failed to create event smoke-test document." >&2
  printf '%s\n' "$create_result" >&2
  exit 1
fi

update_payload=$(cat <<EOF
{"params":{"properties":"dc:title=Codex Audit Smoke Updated\\nnote:note=updated event body"},"input":"doc:$doc_uid"}
EOF
)

update_result=$(run_in_nuxeo "wget --content-on-error -qO- --user Administrator --password Administrator --header=\"Content-Type: application/json\" --post-data='$update_payload' http://127.0.0.1:8080/nuxeo/site/automation/Document.Update")
updated_title=$(extract_json_field "title" "$update_result")

if [ "$updated_title" != "Codex Audit Smoke Updated" ]; then
  printf '%s\n' "Failed to update event smoke-test document." >&2
  printf '%s\n' "$update_result" >&2
  exit 1
fi

audit_result=$(run_in_nuxeo "curl -sS -u Administrator:Administrator http://127.0.0.1:8080/nuxeo/api/v1/id/$doc_uid/@audit?pageSize=20")

created_count=$(printf '%s' "$audit_result" | grep -o '"eventId":"documentCreated"' | wc -l | tr -d ' ')
modified_count=$(printf '%s' "$audit_result" | grep -o '"eventId":"documentModified"' | wc -l | tr -d ' ')
created_at=$(printf '%s' "$audit_result" | sed -n 's/.*"eventId":"documentCreated".*"eventDate":"\([^"]*\)".*/\1/p')
modified_at=$(printf '%s' "$audit_result" | sed -n 's/.*"eventId":"documentModified".*"eventDate":"\([^"]*\)".*/\1/p')

if [ "$created_count" -lt 1 ] || [ "$modified_count" -lt 1 ]; then
  printf '%s\n' "Audit did not show the expected documentCreated/documentModified entries." >&2
  printf '%s\n' "$audit_result" >&2
  exit 1
fi

printf '%s\n' "Event audit OK:"
printf '  %s\n' "document uid: $doc_uid"
printf '  %s\n' "document path: $doc_path"
printf '  %s\n' "documentCreated at: ${created_at:-missing}"
printf '  %s\n' "documentModified at: ${modified_at:-missing}"
printf '%s\n' "Event smoke test passed."
