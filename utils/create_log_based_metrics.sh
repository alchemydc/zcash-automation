#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u

# --- Configuration ---
METRIC_ID="zebrad_current_height"
METRIC_DESCRIPTION="Tracks the current blockchain height reported by Zebrad sync progress logs."
LOG_ID="syslog" # The log stream ID (e.g., syslog, stdout, etc.)
# Adjust the filter parts below if needed (e.g., specific resource name)
INSTANCE_RESOURCE_FILTER='labels."compute.googleapis.com/resource_name"="zebra-archivenode"' # Or "" to skip
MESSAGE_FILTER_1='jsonPayload.message:"zebrad::components::sync::progress:"'
MESSAGE_FILTER_2='jsonPayload.message:"current_height=Height("'
VALUE_EXTRACTOR_REGEX='current_height=Height\\((\\d+)\\)' # Regex to get the value
# Define label extractors as a comma-separated string or leave empty ""
LABEL_EXTRACTORS='instance_name=EXTRACT(labels."compute.googleapis.com/resource_name"),zone=EXTRACT(resource.labels.zone)'
METRIC_UNIT="1"
# --- End Configuration ---

# Get the currently configured project ID
PROJECT_ID=$(gcloud config get-value project)

if [[ -z "${PROJECT_ID}" ]]; then
  echo "ERROR: No active GCP project is configured. Use 'gcloud config set project <PROJECT_ID>'."
  exit 1
fi

echo "Detected active project: ${PROJECT_ID}"
echo "Preparing to create metric '${METRIC_ID}' in project '${PROJECT_ID}'..."

# Construct the log filter dynamically
LOG_FILTER="logName=\"projects/${PROJECT_ID}/logs/${LOG_ID}\" AND resource.type=\"gce_instance\""
if [[ -n "${INSTANCE_RESOURCE_FILTER}" ]]; then
  LOG_FILTER+=" AND ${INSTANCE_RESOURCE_FILTER}"
fi
LOG_FILTER+=" AND ${MESSAGE_FILTER_1}"
LOG_FILTER+=" AND ${MESSAGE_FILTER_2}"

# Construct the value extractor
DISTRIBUTION_EXTRACTOR="REGEXP_EXTRACT(jsonPayload.message, \"${VALUE_EXTRACTOR_REGEX}\")"

# Prepare label extractor flag if labels are defined
LABEL_FLAG=""
if [[ -n "${LABEL_EXTRACTORS}" ]]; then
  LABEL_FLAG="--label-extractors=${LABEL_EXTRACTORS}"
fi

# Construct and run the gcloud command
echo "Executing gcloud command..."
gcloud logging metrics create "${METRIC_ID}" \
    --description="${METRIC_DESCRIPTION}" \
    --log-filter="${LOG_FILTER}" \
    --distribution-value-extractor="${DISTRIBUTION_EXTRACTOR}" \
    --unit="${METRIC_UNIT}" \
    ${LABEL_FLAG} # This expands to nothing if LABEL_FLAG is empty

echo "Metric '${METRIC_ID}' creation command executed for project '${PROJECT_ID}'."
echo "Note: It may take a few minutes for the metric to become active and process new logs."