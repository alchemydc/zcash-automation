#!/bin/bash
set -euo pipefail

PROJECT_ID="$1"
DEPLOYMENT_NAME="$2"
NETWORK_NAME="$3"
DISK_NAME="$4"

# The external data source sends a JSON query on stdin. This helper does not
# need it, but reading it avoids surprising downstream consumers that expect
# stdin to be consumed.
cat >/dev/null || true

snapshot_row="$(gcloud compute snapshots list \
    --project "$PROJECT_ID" \
    --filter "labels.stack=z3 AND labels.deployment=$DEPLOYMENT_NAME AND labels.network=$NETWORK_NAME AND labels.role=zebra-data AND labels.source_disk=$DISK_NAME" \
    --sort-by=~creationTimestamp \
    --limit=1 \
    --format 'csv[no-heading](name,diskSizeGb)' || true)"

if [ -z "$snapshot_row" ]; then
    printf '{"snapshot_name":"","snapshot_size_gb":"0"}\n'
    exit 0
fi

IFS=',' read -r snapshot_name snapshot_size_gb <<EOF
$snapshot_row
EOF

printf '{"snapshot_name":"%s","snapshot_size_gb":"%s"}\n' "$snapshot_name" "${snapshot_size_gb:-0}"