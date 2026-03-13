#!/bin/bash
set -euo pipefail
set -x

GCLOUD_ENV_FILE="gcloud.env"
SERVICE_ACCOUNT_NAME="terraform"
TERRAFORM_SA_DISPLAY_NAME="Terraform admin account"
MAX_WAIT_SECONDS=180
RETRY_INTERVAL_SECONDS=10
DEFAULT_BACKEND_TYPE="local"

require_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Error: Required command '$command_name' is not installed"
        exit 1
    fi
}

detect_terraform_cmd() {
    if command -v terraform >/dev/null 2>&1; then
        TERRAFORM_CMD=$(command -v terraform)
    elif command -v tofu >/dev/null 2>&1; then
        TERRAFORM_CMD=$(command -v tofu)
    else
        echo "Error: Neither terraform nor tofu is installed"
        echo "Please install either Terraform or OpenTofu to continue"
        exit 1
    fi
}

write_env_template() {
    cat <<'EOF' > "$GCLOUD_ENV_FILE"
# Required for both new and existing projects
export TF_VAR_project=YOUR_TERRAFORM_GCP_PROJECT_NAME
export TF_VAR_region=YOUR_TERRAFORM_GCP_REGION_NAME
export TF_VAR_zone=YOUR_TERRAFORM_GCP_ZONE_NAME

# Terraform backend type: local (default) or gcs
export TF_BACKEND=local

# Required only when bootstrap should create a new project
# org ID: get with `gcloud organizations list --format="value(ID)"`
export TF_VAR_org_id=YOUR_GCLOUD_ORG_ID
# billing account: get with `gcloud billing accounts list --format="value(name)"`
export TF_VAR_billing_account=YOUR_GCLOUD_BILLING_ACCOUNT_ID

# DO NOT CHANGE ANYTHING BELOW THIS LINE
# bootstrap.sh manages these values for short-lived credentials and runtime service accounts
EOF
}

normalize_backend_type() {
    local raw_backend="${TF_BACKEND:-$DEFAULT_BACKEND_TYPE}"
    echo "$raw_backend" | tr '[:upper:]' '[:lower:]'
}

validate_backend_type() {
    local backend_type="$1"

    case "$backend_type" in
        local|gcs)
            ;;
        *)
            echo "Error: Unsupported TF_BACKEND '${backend_type}'. Supported values are 'local' and 'gcs'."
            exit 1
            ;;
    esac
}

require_env_var() {
    local var_name="$1"

    if [ -z "${!var_name:-}" ]; then
        echo "Error: Required environment variable '$var_name' is not set"
        exit 1
    fi
}

project_exists() {
    gcloud projects describe "${TF_VAR_project}" >/dev/null 2>&1
}

service_account_email() {
    echo "${SERVICE_ACCOUNT_NAME}@${TF_VAR_project}.iam.gserviceaccount.com"
}

service_account_exists() {
    gcloud iam service-accounts describe "$(service_account_email)" \
        --project "${TF_VAR_project}" >/dev/null 2>&1
}

ensure_export_line() {
    local variable_name="$1"
    local variable_value="$2"
    local temp_file

    temp_file=$(mktemp)
    if [ -f "$GCLOUD_ENV_FILE" ]; then
        grep -v "^export ${variable_name}=" "$GCLOUD_ENV_FILE" > "$temp_file" || true
    fi
    printf 'export %s=%s\n' "$variable_name" "$variable_value" >> "$temp_file"
    mv "$temp_file" "$GCLOUD_ENV_FILE"
}

ensure_token_line() {
    local temp_file

    temp_file=$(mktemp)
    if [ -f "$GCLOUD_ENV_FILE" ]; then
        grep -v '^export GOOGLE_OAUTH_ACCESS_TOKEN=' "$GCLOUD_ENV_FILE" > "$temp_file" || true
    fi
    echo 'export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token --impersonate-service-account terraform@${TF_VAR_project}.iam.gserviceaccount.com)' >> "$temp_file"
    mv "$temp_file" "$GCLOUD_ENV_FILE"
}

ensure_project() {
    if project_exists; then
        echo "Using existing GCP project ${TF_VAR_project}"
        gcloud config set project "${TF_VAR_project}"
        return
    fi

    require_env_var TF_VAR_org_id
    require_env_var TF_VAR_billing_account

    echo "Creating new GCP project ${TF_VAR_project}"
    gcloud projects create "${TF_VAR_project}" \
        --organization "${TF_VAR_org_id}" \
        --set-as-default

    echo "Linking ${TF_VAR_project} to billing account ${TF_VAR_billing_account}"
    gcloud billing projects link "${TF_VAR_project}" \
        --billing-account "${TF_VAR_billing_account}"
}

ensure_service_account() {
    if service_account_exists; then
        echo "Terraform service account already exists: $(service_account_email)"
        return
    fi

    echo "Creating IAM service account for Terraform"
    gcloud iam service-accounts create "${SERVICE_ACCOUNT_NAME}" \
        --display-name "${TERRAFORM_SA_DISPLAY_NAME}" \
        --project "${TF_VAR_project}"
}

wait_for_impersonation() {
    local start_time
    local current_time
    local elapsed

    start_time=$(date +%s)

    while true; do
        if gcloud auth print-access-token \
            --project "${TF_VAR_project}" \
            --impersonate-service-account "$(service_account_email)" >/dev/null 2>&1; then
            echo "Successfully generated impersonated access token"
            return
        fi

        current_time=$(date +%s)
        elapsed=$((current_time - start_time))

        if [ "$elapsed" -ge "$MAX_WAIT_SECONDS" ]; then
            echo "Error: Failed to generate an impersonated access token after ${MAX_WAIT_SECONDS} seconds"
            exit 1
        fi

        echo "Waiting for service account to be ready... (${elapsed}s elapsed)"
        sleep "$RETRY_INTERVAL_SECONDS"
    done
}

ensure_project_iam_bindings() {
    local terraform_sa="$1"
    local role
    local terraform_roles=(
        "roles/editor"
        "roles/storage.admin"
        "roles/iam.serviceAccountUser"
        "roles/logging.configWriter"
        "roles/monitoring.admin"
    )

    for role in "${terraform_roles[@]}"; do
        gcloud projects add-iam-policy-binding "${TF_VAR_project}" \
            --member "serviceAccount:${terraform_sa}" \
            --role "$role" >/dev/null
    done
}

ensure_required_apis() {
    local api
    local required_apis=(
        "compute.googleapis.com"
        "cloudresourcemanager.googleapis.com"
        "cloudbilling.googleapis.com"
        "iam.googleapis.com"
        "serviceusage.googleapis.com"
        "monitoring.googleapis.com"
        "logging.googleapis.com"
        "clouderrorreporting.googleapis.com"
        "iap.googleapis.com"
    )

    for api in "${required_apis[@]}"; do
        gcloud services enable "$api" --project "${TF_VAR_project}"
    done
}

ensure_default_compute_service_account() {
    local project_number
    local default_compute_sa
    local role
    # compute.storageAdmin is needed for creating snapshots from disks. todo: reduce permissions
    local compute_roles=(
        "roles/compute.storageAdmin"
        "roles/logging.logWriter"
        "roles/monitoring.metricWriter"
    )

    project_number=$(gcloud projects describe "${TF_VAR_project}" --format="value(projectNumber)")
    default_compute_sa="${project_number}-compute@developer.gserviceaccount.com"

    for role in "${compute_roles[@]}"; do
        gcloud projects add-iam-policy-binding "${TF_VAR_project}" \
            --member "serviceAccount:${default_compute_sa}" \
            --role "$role" >/dev/null
    done

    ensure_export_line "TF_VAR_GCP_DEFAULT_SERVICE_ACCOUNT" "$default_compute_sa"
    echo "Default Compute Engine service account: ${default_compute_sa}"
}

ensure_state_bucket() {
    local terraform_sa="$1"
    local state_bucket="${TF_VAR_project}-tfstate"
    local temp_policy_file

    if ! gsutil ls -b "gs://${state_bucket}" >/dev/null 2>&1; then
        echo "Creating Terraform state bucket gs://${state_bucket}"
        gsutil mb -p "${TF_VAR_project}" "gs://${state_bucket}"
    else
        echo "Terraform state bucket already exists: gs://${state_bucket}"
    fi

    gsutil versioning set on "gs://${state_bucket}"

    temp_policy_file=$(mktemp)
    cat > "$temp_policy_file" <<EOF
{
  "bindings": [
    {
      "members": [
        "projectOwner:${TF_VAR_project}",
        "serviceAccount:${terraform_sa}"
      ],
      "role": "roles/storage.admin"
    }
  ],
  "version": 1
}

configure_backend() {
    local backend_type="$1"
    local terraform_sa="$2"

    case "$backend_type" in
        gcs)
            require_command gsutil
            ensure_state_bucket "$terraform_sa"
            ;;
        local)
            if [ -f backend.tf ]; then
                echo "Using local backend; removing existing backend.tf"
                rm -f backend.tf
            else
                echo "Using local backend"
            fi
            ;;
    esac
}
EOF
    gsutil iam set "$temp_policy_file" "gs://${state_bucket}"
    rm -f "$temp_policy_file"

    cat > backend.tf <<EOF
terraform {
 backend "gcs" {
   bucket  = "${state_bucket}"
   prefix  = "terraform/state"
 }
}
EOF
}

detect_terraform_cmd
require_command gcloud

echo "Using ${TERRAFORM_CMD} as Terraform provider"

if [ ! -f "$GCLOUD_ENV_FILE" ]; then
    write_env_template
    echo "Please set gcloud environment variables in ${GCLOUD_ENV_FILE} before running $0"
    exit 1
fi

echo "Sourcing gcloud environment variables from ${GCLOUD_ENV_FILE}"
# shellcheck disable=SC1090
source "$GCLOUD_ENV_FILE"

require_env_var TF_VAR_project
require_env_var TF_VAR_region
require_env_var TF_VAR_zone

BACKEND_TYPE=$(normalize_backend_type)
validate_backend_type "$BACKEND_TYPE"
echo "Selected Terraform backend: ${BACKEND_TYPE}"

ensure_project
ensure_service_account
wait_for_impersonation
ensure_token_line

TERRAFORM_SA=$(service_account_email)
echo "Terraform service account: ${TERRAFORM_SA}"

ensure_project_iam_bindings "$TERRAFORM_SA"
ensure_required_apis
ensure_default_compute_service_account
configure_backend "$BACKEND_TYPE" "$TERRAFORM_SA"

echo "Sourcing ${GCLOUD_ENV_FILE} with refreshed credentials"
# shellcheck disable=SC1091
source ./gcloud.env

echo "Initializing Terraform"
"$TERRAFORM_CMD" init

echo "Terraform is ready to use with project ${TF_VAR_project}"
