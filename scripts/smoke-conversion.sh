#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMPOSE_FILE=$ROOT_DIR/compose.yaml
SERVICE=nuxeo
NAMESPACE=codex-conversion-$(date +%Y%m%d%H%M%S)

run_in_nuxeo() {
  docker compose -f "$COMPOSE_FILE" exec -T "$SERVICE" bash -lc "$1"
}

create_document() {
  doc_type=$1
  doc_name=$2
  doc_title=$3

  run_in_nuxeo "payload=\$(cat <<EOF
{\"params\":{\"type\":\"$doc_type\",\"name\":\"$doc_name\",\"properties\":\"dc:title=$doc_title\"},\"input\":\"doc:/default-domain/workspaces\"}
EOF
); wget --content-on-error -qO- --user Administrator --password Administrator --header=\"Content-Type: application/json\" --post-data=\"\$payload\" http://127.0.0.1:8080/nuxeo/site/automation/Document.Create"
}

extract_json_field() {
  field_name=$1
  printf '%s' "$2" | tr -d '\n' | sed -n "s/.*\"$field_name\":\"\\([^\"]*\\)\".*/\\1/p"
}

printf '%s\n' "Running conversion smoke test against $SERVICE..."

office_doc_json=$(create_document "File" "$NAMESPACE-odt" "Codex Conversion Smoke")
office_doc_uid=$(extract_json_field "uid" "$office_doc_json")
office_doc_path=$(extract_json_field "path" "$office_doc_json")

if [ -z "$office_doc_uid" ] || [ -z "$office_doc_path" ]; then
  printf '%s\n' "Failed to create Office smoke-test document." >&2
  printf '%s\n' "$office_doc_json" >&2
  exit 1
fi

run_in_nuxeo "printf 'Conversion smoke sample\n' >/tmp/$NAMESPACE.txt && soffice --headless --convert-to odt --outdir /tmp /tmp/$NAMESPACE.txt >/tmp/$NAMESPACE-soffice.log 2>&1 && test -s /tmp/$NAMESPACE.odt"
run_in_nuxeo "curl --fail-with-body -sS -u Administrator:Administrator -X PUT -H 'Content-Type: application/vnd.oasis.opendocument.text' -T /tmp/$NAMESPACE.odt http://127.0.0.1:8080/nuxeo/api/v1/id/$office_doc_uid/@blob/file:content >/tmp/$NAMESPACE-upload.log"
run_in_nuxeo "payload=\$(cat <<EOF
{\"input\":\"doc:$office_doc_uid\"}
EOF
); wget --content-on-error -qO /tmp/$NAMESPACE.pdf --user Administrator --password Administrator --header=\"Content-Type: application/json\" --post-data=\"\$payload\" http://127.0.0.1:8080/nuxeo/site/automation/Blob.ToPDF && test \"\$(head -c 5 /tmp/$NAMESPACE.pdf)\" = '%PDF-'"

printf '%s\n' "Office conversion OK:"
printf '  %s\n' "document uid: $office_doc_uid"
printf '  %s\n' "document path: $office_doc_path"
printf '  %s\n' "PDF produced via Blob.ToPDF"

video_op_present=$(run_in_nuxeo "curl -sS -u Administrator:Administrator http://127.0.0.1:8080/nuxeo/site/automation | tr -d '\n' | grep -c '\"id\":\"Video.Slice\"'" || true)

if [ "${video_op_present:-0}" -gt 0 ]; then
  video_doc_json=$(create_document "Video" "$NAMESPACE-video" "Codex Video Smoke")
  video_doc_uid=$(extract_json_field "uid" "$video_doc_json")

  if [ -z "$video_doc_uid" ]; then
    printf '%s\n' "Failed to create Video smoke-test document." >&2
    printf '%s\n' "$video_doc_json" >&2
    exit 1
  fi

  run_in_nuxeo "ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc=size=160x120:rate=1 -t 2 -pix_fmt yuv420p /tmp/$NAMESPACE.mp4 && test -s /tmp/$NAMESPACE.mp4"
  run_in_nuxeo "curl --fail-with-body -sS -u Administrator:Administrator -X PUT -H 'Content-Type: video/mp4' -T /tmp/$NAMESPACE.mp4 http://127.0.0.1:8080/nuxeo/api/v1/id/$video_doc_uid/@blob/file:content >/tmp/$NAMESPACE-video-upload.log"

  video_converted=0
  poll_attempts=24
  poll_sleep=5
  i=0
  while [ "$i" -lt "$poll_attempts" ]; do
    vid_props=$(run_in_nuxeo "curl -sS -u Administrator:Administrator \
      'http://127.0.0.1:8080/nuxeo/api/v1/id/$video_doc_uid?schemas=vid'" || true)
    transcoded_count=$(printf '%s' "$vid_props" \
      | grep -o '"vid:transcodedVideos":\[[^]]*.\]' \
      | grep -c '"content"' || true)
    if [ "${transcoded_count:-0}" -gt 0 ]; then
      video_converted=1
      break
    fi
    i=$((i + 1))
    sleep "$poll_sleep"
  done

  if [ "$video_converted" -eq 0 ]; then
    printf '%s\n' \
      "Video conversion did not complete within $((poll_attempts * poll_sleep))s for uid $video_doc_uid." >&2
    exit 1
  fi

  printf '%s\n' "Video conversion OK:"
  printf '  %s\n' "document uid: $video_doc_uid"
  printf '  %s\n' "vid:transcodedVideos populated after async conversion"
else
  printf '%s\n' "Video.Slice is not exposed by the running Nuxeo automation catalog; skipping FFmpeg probe."
fi

printf '%s\n' "Conversion smoke test passed."
