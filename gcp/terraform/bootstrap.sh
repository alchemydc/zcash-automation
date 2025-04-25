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

echo "Creating IAM service account for terraform"
gcloud iam service-accounts create terraform \
    --display-name "Terraform admin account"


echo "Waiting for service account to propagate and generating short lived (impersonated) access token..."
start_time=$(date +%s)
max_wait=180  # 3 minutes in seconds
retry_interval=10

while true; do
    if gcloud auth print-access-token --impersonate-service-account "terraform@${TF_VAR_project}.iam.gserviceaccount.com"  >/dev/null 2>&1; then
        echo "Successfully generated access token"
        break
    fi

    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    
    if [ $elapsed -ge $max_wait ]; then
        echo "Error: Failed to generate access token after ${max_wait} seconds"
        exit 1
    fi

    echo "Waiting for service account to be ready... (${elapsed}s elapsed)"
    sleep $retry_interval
done

# setup gcloud.env to auto-refresh creds
echo "Configuring gcloud.env to get a new short lived access token when sourced"
echo 'export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token --impersonate-service-account terraform@${TF_VAR_project}.iam.gserviceaccount.com)' >> gcloud.env

echo "Granting required roles to terraform service account (infra/admin roles)"
echo "Terraform service account: ${TERRAFORM_SA}"
TF_VAR_GCP_DEFAULT_SERVICE_ACCOUNT="terraform@${TF_VAR_project}.iam.gserviceaccount.com"
TERRAFORM_SA=${TF_VAR_GCP_DEFAULT_SERVICE_ACCOUNT}
TERRAFORM_ROLES=(
    "roles/editor"
    "roles/storage.admin"
    "roles/iam.serviceAccountUser"
    "roles/logging.configWriter"
    "roles/monitoring.admin"
)

for ROLE in "${TERRAFORM_ROLES[@]}"; do
    gcloud projects add-iam-policy-binding ${TF_VAR_project} \
        --member "serviceAccount:${TERRAFORM_SA}" \
        --role ${ROLE}
done

echo "Enabling required gcp API's"
REQUIRED_APIS=(
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

for API in "${REQUIRED_APIS[@]}"; do
    gcloud services enable ${API}
done

# add the project specific default compute service account to gcloud.env
echo "adding the default compute service account to gcloud.env"
PROJECT_NUMBER=$(gcloud projects describe "${TF_VAR_project}" --format="value(projectNumber)")
DEFAULT_COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
TF_VAR_GCP_DEFAULT_SERVICE_ACCOUNT="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
echo "export TF_VAR_GCP_DEFAULT_SERVICE_ACCOUNT=$DEFAULT_COMPUTE_SA" >> gcloud.env
echo "Granting required roles to default Compute Engine service account (runtime/logging/monitoring roles)"
COMPUTE_ROLES=(
    "roles/logging.logWriter"
    "roles/monitoring.metricWriter"
)

for ROLE in "${COMPUTE_ROLES[@]}"; do
    gcloud projects add-iam-policy-binding ${TF_VAR_project} \
        --member "serviceAccount:${DEFAULT_COMPUTE_SA}" \
        --role ${ROLE}
done
echo "Default Compute Engine service account: ${DEFAULT_COMPUTE_SA}"

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
