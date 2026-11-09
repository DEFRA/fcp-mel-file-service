#!/usr/bin/env bash

# Development-only, manually invoked project CSV transfer.
# Never deletes SharePoint files or writes directly to S3.

set +x
set -euo pipefail
umask 077

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

MODE="${1:---folders}"
case "$MODE" in
  --folders|--preview|--apply) ;;
  *) die "Usage: bash sharepoint-project-to-s3.sh --folders|--preview|--apply" ;;
esac

[[ "${SERVICE:-}" == "fcp-mel-file-service" ]] ||
  die "Run in the file-service CDP Terminal."

[[ "${ENVIRONMENT:-}" == "dev" ]] ||
  die "Dev only."

: "${ENTRA_TENANT_ID:?Set your full Entra tenant ID}"

[[ "$ENTRA_TENANT_ID" =~ ^[A-Fa-f0-9-]{36}$ ]] ||
  die "Invalid tenant ID format."

for tool in aws curl jq openssl mktemp; do
  command -v "$tool" >/dev/null || die "Missing tool: $tool"
done

CLIENT_ID="a50ffde5-f9e1-45d2-9fd7-680bccacb158"
PROXY="http://localhost:3128"
GRAPH="https://graph.microsoft.com/v1.0"
UPLOADER="https://cdp-uploader.dev.cdp-int.defra.cloud"
BUCKET="dev-fcp-mel-ingestion-files-c63f2"

DRIVE_ID="b!0cG1tOHq70uy_oXFfWez7KRKnrxp7fdJmWCuAsaQnRBi-7QMq6NARrae9qvy5e7D"
ROOT_PATH="13.%20Data%20Management/Datastore/DDTS%20Ready%20Database%20data"

MAX_FILES="${MAX_FILES:-1}"
MAX_BYTES=20971520
POLL_SECONDS=5
POLL_ATTEMPTS=120

[[ "$MAX_FILES" =~ ^[1-9][0-9]*$ ]] ||
  die "MAX_FILES must be a positive integer."

TMP=$(mktemp -d)
LOCK=""

cleanup() {
  rm -rf "$TMP"
  if [[ -n "$LOCK" ]]; then
    rmdir "$LOCK" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Never print raw HTTP responses: they can contain tokens/download URLs.
request() {
  local output="$1"
  shift
  local code

  if ! code=$(curl \
      --silent --show-error \
      --connect-timeout 10 --max-time 60 \
      --proxy "$PROXY" \
      --output "$output" \
      --write-out '%{http_code}' \
      "$@"); then
    die "Network request failed; no automatic POST retry."
  fi

  case "$code" in
    2??) ;;
    *) die "HTTP $code. Raw response withheld." ;;
  esac

  jq -e 'type == "object"' "$output" >/dev/null ||
    die "Expected a JSON object."
}

authenticate() {
  aws sts get-web-identity-token \
    --region eu-west-2 \
    --endpoint-url https://sts.eu-west-2.amazonaws.com \
    --audience 'api://AzureADTokenExchange' \
    --signing-algorithm RS256 \
    --duration-seconds 300 \
    --output json > "$TMP/aws-token.json"

  jq -erj '.WebIdentityToken | select(length > 0)' \
    "$TMP/aws-token.json" > "$TMP/assertion.txt"

  request "$TMP/token.json" \
    -X POST \
    "https://login.microsoftonline.com/$ENTRA_TENANT_ID/oauth2/v2.0/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "client_id=$CLIENT_ID" \
    --data-urlencode 'scope=https://graph.microsoft.com/.default' \
    --data-urlencode 'grant_type=client_credentials' \
    --data-urlencode \
      'client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer' \
    --data-urlencode "client_assertion@$TMP/assertion.txt"

  jq -er '
    .access_token
    | select(type == "string" and length > 0)
    | "Authorization: Bearer " + .
  ' "$TMP/token.json" > "$TMP/header"

  rm -f "$TMP/aws-token.json" "$TMP/assertion.txt" "$TMP/token.json"
}

graph_get() {
  local url="$1"
  local output="$2"

  case "$url" in
    "$GRAPH/"*) ;;
    *) die "Refusing to send Graph credentials to another host." ;;
  esac

  request "$output" --header "@$TMP/header" "$url"
}

list_children() {
  local next="$1"
  local output="$2"

  : > "$output"

  while [[ -n "$next" ]]; do
    authenticate
    graph_get "$next" "$TMP/page.json"

    jq -e '.value | type == "array"' "$TMP/page.json" >/dev/null ||
      die "Unexpected Graph listing."

    jq -c '.value[]' "$TMP/page.json" >> "$output"
    next=$(jq -r '."@odata.nextLink" // empty' "$TMP/page.json")
  done
}

save_record() {
  printf '%s\n' "$RECORD" > "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}

ROOT_URL="$GRAPH/drives/$DRIVE_ID/root:/$ROOT_PATH:/children?\$select=id,name,folder&\$top=100"
list_children "$ROOT_URL" "$TMP/root-items.jsonl"

if [[ "$MODE" == "--folders" ]]; then
  jq -s '
    map(select(.folder != null) |
      {folderId: .id, folderName: .name})
  ' "$TMP/root-items.jsonl"
  exit 0
fi

: "${PROJECT_ID:?Set the stable project ID}"
: "${PROJECT_FOLDER_NAME:?Set the exact SharePoint project-folder name}"

[[ "$PROJECT_ID" =~ ^[a-z0-9][a-z0-9_-]*$ ]] ||
  die "Use lowercase letters, digits, underscores or hyphens for PROJECT_ID."

# Select only a folder directly inside the approved root.
jq -s --arg name "$PROJECT_FOLDER_NAME" '
  map(select(.folder != null and .name == $name))
' "$TMP/root-items.jsonl" > "$TMP/folders.json"

[[ "$(jq 'length' "$TMP/folders.json")" -eq 1 ]] ||
  die "Expected exactly one matching project folder under the approved root."

FOLDER_ID=$(jq -er '.[0].id' "$TMP/folders.json")
ENCODED_FOLDER_ID=$(jq -nr --arg id "$FOLDER_ID" '$id | @uri')

CHILD_URL="$GRAPH/drives/$DRIVE_ID/items/$ENCODED_FOLDER_ID/children?\$select=id,name,size,eTag,file,folder&\$top=100"
list_children "$CHILD_URL" "$TMP/children.jsonl"

# This first version transfers direct CSV files only.
jq -s '
  map(select(.file != null and (.name | test("\\.csv$"; "i"))))
  | sort_by(.name)
  | .[]
' -c "$TMP/children.jsonl" > "$TMP/csv-files.jsonl"

echo "Project: $PROJECT_ID"
echo "Direct CSV files:"
jq -s 'map({id, name, size})' "$TMP/csv-files.jsonl"

echo "Excluded folders and non-CSV items:"
jq -s '
  map(select(
    .folder != null or
    (.file == null) or
    (.name | test("\\.csv$"; "i") | not)
  ) | length
' "$TMP/children.jsonl"

# Optional: limit selection to one explicit source item.
if [[ -n "${SOURCE_ITEM_ID:-}" ]]; then
  jq -c --arg id "$SOURCE_ITEM_ID" \
    'select(.id == $id)' \
    "$TMP/csv-files.jsonl" > "$TMP/selected.jsonl"

  [[ -s "$TMP/selected.jsonl" ]] ||
    die "SOURCE_ITEM_ID is not a CSV in the selected folder."
else
  cp "$TMP/csv-files.jsonl" "$TMP/selected.jsonl"
fi

[[ "$MODE" == "--apply" ]] || exit 0

[[ "${APPROVED_FOR_DEV:-}" == "yes" ]] ||
  die "Set APPROVED_FOR_DEV=yes only for approved data."

STATE_DIR="${STATE_DIR:-$HOME/mel-transfer-state/$PROJECT_ID}"
mkdir -p "$STATE_DIR"

mkdir "$STATE_DIR/.lock" 2>/dev/null ||
  die "Run active or stale lock exists; investigate first."
LOCK="$STATE_DIR/.lock"

COUNT=0

while IFS= read -r ITEM; do
  [[ "$COUNT" -lt "$MAX_FILES" ]] || break

  ID=$(jq -er '.id' <<< "$ITEM")
  TAG=$(jq -er '.eTag' <<< "$ITEM")
  SIZE=$(jq -er '.size' <<< "$ITEM")

  [[ "$SIZE" -gt 0 && "$SIZE" -le "$MAX_BYTES" ]] ||
    die "Selected file is empty or exceeds the 20 MiB pilot limit."

  # Different source versions have different records.
  HASH=$(
    printf '%s\n%s\n%s\n%s' "$PROJECT_ID" "$DRIVE_ID" "$ID" "$TAG" |
      openssl dgst -sha256
  )
  RECORD_ID="${HASH##* }"
  STATE_FILE="$STATE_DIR/$RECORD_ID.json"

  if [[ -f "$STATE_FILE" ]]; then
    RECORD=$(cat "$STATE_FILE")
    STATUS=$(jq -er '.status' <<< "$RECORD")

    if [[ "$STATUS" == "complete" ]]; then
      echo "Skipping completed source item: $ID"
      continue
    fi

    # Resume polling rather than submit another copy.
    [[ "$STATUS" == "pending" ]] ||
      die "Existing $STATUS record; reconcile it before retrying."

    UPLOAD_ID=$(jq -er '.uploadId' <<< "$RECORD")
    echo "Resuming status checks for: $UPLOAD_ID"
  else
    authenticate

    ENCODED_ID=$(jq -nr --arg id "$ID" '$id | @uri')
    graph_get \
      "$GRAPH/drives/$DRIVE_ID/items/$ENCODED_ID" \
      "$TMP/item.json"

    jq -e --arg tag "$TAG" '
      .file != null and
      .eTag == $tag and
      (."@microsoft.graph.downloadUrl" | type == "string")
    ' "$TMP/item.json" >/dev/null ||
      die "Source changed or no download URL returned."

    HOST=$(jq -er '
      ."@microsoft.graph.downloadUrl"
      | capture("^https://(?<host>[^/:?#]+)(?:[/:?#]|$)").host
      | ascii_downcase
    ' "$TMP/item.json")

    [[ "$HOST" == "defra.sharepoint.com" ]] ||
      die "Unexpected download host: $HOST. Confirm approval first."

    RECORD=$(jq -n \
      --arg project "$PROJECT_ID" \
      --arg folderId "$FOLDER_ID" \
      --arg folderName "$PROJECT_FOLDER_NAME" \
      --arg drive "$DRIVE_ID" \
      --argjson source "$ITEM" '
      {
        projectId: $project,
        sourceFolderId: $folderId,
        sourceFolderName: $folderName,
        sourceDriveId: $drive,
        sourceItemId: $source.id,
        sourceName: $source.name,
        sourceETag: $source.eTag,
        sourceSize: $source.size,
        status: "submitting",
        createdAt: (now | todateiso8601)
      }
    ')

    # Preserve uncertainty if a POST succeeds but its response is lost.
    save_record

    jq \
      --arg bucket "$BUCKET" \
      --arg prefix "projects/$PROJECT_ID" \
      --argjson source "$RECORD" '
      {
        s3Bucket: $bucket,
        s3Path: $prefix,
        metadata: ($source | del(.status)),
        downloadUrls: [."@microsoft.graph.downloadUrl"]
      }
    ' "$TMP/item.json" > "$TMP/body.json"

    request "$TMP/initiate.json" \
      -X POST "$UPLOADER/initiate" \
      -H 'Content-Type: application/json' \
      -H 'User-Agent: fcp-mel-file-service-project-pilot' \
      --data-binary "@$TMP/body.json"

    UPLOAD_ID=$(jq -er '.uploadId' "$TMP/initiate.json")

    RECORD=$(jq --arg upload "$UPLOAD_ID" '
      . + {uploadId: $upload, status: "pending"}
    ' <<< "$RECORD")
    save_record

    rm -f "$TMP/item.json" "$TMP/body.json" "$TMP/initiate.json"
  fi

  [[ "$UPLOAD_ID" =~ ^[A-Za-z0-9-]+$ ]] ||
    die "Unexpected upload ID."

  COMPLETE=false

  for ((N=1; N<=POLL_ATTEMPTS; N++)); do
    request "$TMP/status.json" "$UPLOADER/status/$UPLOAD_ID"

    RESULT=$(jq '
      [.form | .. | objects | select(has("fileStatus"))]
      | if length == 1 then
          .[0] | {
            fileStatus, hasError, errorCode, s3Bucket,
            s3Key, checksumSha256, contentLength
          }
        else {}
        end
    ' "$TMP/status.json")

    STATUS=$(jq -r '.fileStatus // "pending"' <<< "$RESULT")
    ERROR=$(jq -r '.hasError // false' <<< "$RESULT")

    if [[ "$STATUS" == "rejected" || "$ERROR" == "true" ]]; then
      RECORD=$(jq --argjson result "$RESULT" '
        . + {status: "rejected", result: $result}
      ' <<< "$RECORD")
      save_record
      die "Upload rejected: $UPLOAD_ID. Inspect the safe state record."
    fi

    if [[ "$STATUS" == "complete" ]]; then
      jq -e \
        --arg bucket "$BUCKET" \
        --arg prefix "projects/$PROJECT_ID/" '
        .s3Bucket == $bucket and
        (.s3Key | type == "string") and
        (.s3Key | startswith($prefix)) and
        (.checksumSha256 | type == "string" and length > 0)
      ' <<< "$RESULT" >/dev/null ||
        die "Unexpected completion destination or missing checksum."

      RECORD=$(jq --argjson result "$RESULT" '
        . + {
          status: "complete",
          completedAt: (now | todateiso8601),
          result: $result
        }
      ' <<< "$RECORD")
      save_record

      echo "Completed: $UPLOAD_ID"
      echo "Transfer record: $STATE_FILE"
      COMPLETE=true
      break
    fi

    sleep "$POLL_SECONDS"
  done

  [[ "$COMPLETE" == "true" ]] ||
    die "Still pending: $UPLOAD_ID. Rerun with the same state to resume polling."

  COUNT=$((COUNT + 1))
done < "$TMP/selected.jsonl"

echo "Completed this run: $COUNT"
echo "Preserve transfer records from: $STATE_DIR"