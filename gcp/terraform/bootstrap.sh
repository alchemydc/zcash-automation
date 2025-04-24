#!/bin/bash
set -ex

##########
# this will create a new project in GCP, and prepare the service account for it as well as necessary API's
# best practice is to use a separate git branch for each environment (eg blue/green)
# dependencies: gcloud cli, terraform cli

GCLOUD_ENV_FILE="gcloud.env"
# Check for terraform or tofu installation
if command -v terraform >/dev/null 2>&1; then
    TERRAFORM_CMD=$(which terraform)
elif command -v tofu >/dev/null 2>&1; then
    TERRAFORM_CMD=$(which tofu)
else
    echo "Error: Neither terraform nor tofu is installed"
    echo "Please install either Terraform or OpenTofu to continue"
    exit 1
fi

# check for proper installation of the gcloud cli SDK
if ! command -v gcloud >/dev/null 2>&1; then
    echo "Error: gcloud CLI is not installed"
    echo "Please install the gcloud CLI to continue"
    exit 1
fi

echo "Using ${TERRAFORM_CMD} as Terraform provider"

echo "Sourcing gcloud env vars from gcloud.env."
if [ -f gcloud.env ]; then
    source gcloud.env
else
    cat <<'EOF' > $GCLOUD_ENV_FILE
    # org ID: get with `gcloud organizations list --format="value(ID)"`
    export TF_VAR_org_id=YOUR_GCLOUD_ORG_ID
    # billing account: get with `gcloud billing accounts list --format="value(name)"`
    export TF_VAR_billing_account=YOUR_GCLOUD_BILLING_ACCOUNT_ID
    # project name: set it to something unique
    export TF_VAR_project=YOUR_TERRAFORM_GCP_PROJECT_NAME
    # region: set to your desired region
    export TF_VAR_region=YOUR_TERRAFORM_GCP_region_NAME
    # zone: set to your desired zone
    export TF_VAR_zone=YOUR_TERRAFORM_ZONE_NAME
    # DO NOT CHANGE ANYTHING BELOW THIS LINE
    # these allow terraform to use the created service account via short-lived credentials
EOF
echo "Please set gcloud environment variables in $GCLOUD_ENV_FILE before running $0"
exit 1
fi

echo "Creating new gcloud project for terraform"
gcloud projects create ${TF_VAR_project} \
    --organization ${TF_VAR_org_id} \
    --set-as-default

echo "Linking new gcloud project to billing account"
gcloud billing projects link ${TF_VAR_project} \
    --billing-account ${TF_VAR_billing_account}

echo "Creating iam service account for terraform"
gcloud iam service-accounts create terraform \
    --display-name "Terraform admin account"

echo "Sleeping to wait for service account to propagate"
sleep 90

echo "Generating short-lived access token for terraform"
gcloud auth print-access-token --impersonate-service-account terraform@${TF_VAR_project}.iam.gserviceaccount.com --format=json

# setup gcloud.env to auto-refresh creds
echo "Configuring gcloud.env to get a new short lived access token when sourced"
echo "export TF_VAR_GCP_DEFAULT_SERVICE_ACCOUNT=terraform@${TF_VAR_project}.iam.gserviceaccount.com" >> gcloud.env
echo 'export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token --impersonate-service-account terraform@${TF_VAR_project}.iam.gserviceaccount.com)' >> gcloud.env

echo "Granting required roles to terraform service account"
# storage.admin is required to write to the tfstate bucket [fixme]
# logging.configWriter is required to write to stackdriver
# editor is required to create and manage resources
# monitoring.admin is required to create and manage monitoring resources
TF_VAR_GCP_DEFAULT_SERVICE_ACCOUNT="terraform@${TF_VAR_project}.iam.gserviceaccount.com"
TERRAFORM_SA=${TF_VAR_GCP_DEFAULT_SERVICE_ACCOUNT}
ROLES=(
    "roles/storage.admin"
    "roles/logging.logWriter"           # Allows writing logs
    "roles/logging.configWriter"        # Allows configuring log sinks and exports
    "roles/monitoring.metricWriter"     # Allows writing metrics
    "roles/monitoring.admin"            # Allows managing monitoring
    "roles/editor"                      # General resource management
    "roles/cloudtrace.agent"           # Allows writing trace data
    "roles/errorreporting.writer"      # Allows writing to Error Reporting
)

for ROLE in "${ROLES[@]}"; do
    gcloud projects add-iam-policy-binding ${TF_VAR_project} \
        --member "serviceAccount:${TERRAFORM_SA}" \
        --role ${ROLE}
done

echo "Enabling required gcp API's for terraform"
REQUIRED_APIS=(
    # Existing APIs
    "cloudresourcemanager.googleapis.com"
    "cloudbilling.googleapis.com"
    "iam.googleapis.com"
    "compute.googleapis.com"
    "serviceusage.googleapis.com"
    "monitoring.googleapis.com"
    "logging.googleapis.com"
    "clouderrorreporting.googleapis.com"
    "iap.googleapis.com"
    # Additional APIs for comprehensive logging
    "cloudtrace.googleapis.com"         # For trace data
    "stackdriver.googleapis.com"        # For legacy Stackdriver features
    "opsconfigmonitoring.googleapis.com" # For Ops Agent configuration
    "cloudprofiler.googleapis.com"      # For performance profiling
)

for API in "${REQUIRED_APIS[@]}"; do
    gcloud services enable ${API}
done

# Create and configure state bucket
echo "Creating and configuring terraform state bucket..."
TF_STATE_BUCKET="${TF_VAR_project}-tfstate"

if ! gsutil mb -p "${TF_VAR_project}" "gs://${TF_STATE_BUCKET}"; then
    echo "Error: Failed to create state bucket"
    exit 1
fi

# Configure state bucket to use versioning
gsutil versioning set on "gs://${TF_STATE_BUCKET}"

# Create IAM policy for the state bucket
cat > iam.json << EOF
{
  "bindings": [
    {
      "members": [
        "projectOwner:${TF_VAR_project}",
        "serviceAccount:${TERRAFORM_SA}"
      ],
      "role": "roles/storage.admin"
    }
  ],
  "version": 1
}
EOF

# Apply the IAM policy to the state bucket
gsutil iam set iam.json gs://${TF_STATE_BUCKET}
rm -f iam.json

# Create Terraform backend configuration
cat > backend.tf << EOF
terraform {
 backend "gcs" {
   bucket  = "${TF_STATE_BUCKET}"
   prefix  = "terraform/state"
 }
}
EOF

echo "Don't forget to 'source gcloud.env' before using Terraform each session"
echo "A dynamically named service account was created that Terraform needs to know about"
echo "Sourcing gcloud.env will set the GOOGLE_APPLICATION_CREDENTIALS environment variable to the short lived service account token"
echo "These tokens expire after 1 hour, so you will need to re-source gcloud.env to get a new token"
echo "Sourcing gcloud.env"
# Source the environment with new credentials
if ! source ./gcloud.env; then
    echo "Error: Failed to initialize credentials"
    exit 1
fi

echo "Initializing terraform"
$TERRAFORM_CMD init

echo "Terraform is now ready to use with the new project"
