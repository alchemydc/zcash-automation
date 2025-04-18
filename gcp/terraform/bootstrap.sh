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
    # these allow terraform to use the created service account via downloaded creds
    export TF_CREDS=~/.config/gcloud/${USER}-${TF_VAR_project}.json
    export GOOGLE_APPLICATION_CREDENTIALS=${TF_CREDS}
    export GOOGLE_PROJECT=${TF_VAR_project}
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

echo "Creating gcloud keys on filesystem for terraform"
gcloud iam service-accounts keys create ${TF_CREDS} \
    --iam-account terraform@${TF_VAR_project}.iam.gserviceaccount.com

echo "Granting required roles to terraform service account"
TERRAFORM_SA="serviceAccount:terraform@${TF_VAR_project}.iam.gserviceaccount.com"
ROLES=(
    "roles/storage.admin"
    "roles/logging.configWriter"
    "roles/editor"
    "roles/monitoring.admin"
)

for ROLE in "${ROLES[@]}"; do
    gcloud projects add-iam-policy-binding ${TF_VAR_project} \
        --member ${TERRAFORM_SA} \
        --role ${ROLE}
done

echo "Enabling required gcp API's for terraform"
REQUIRED_APIS=(
    "cloudresourcemanager.googleapis.com"
    "cloudbilling.googleapis.com"
    "iam.googleapis.com"
    "compute.googleapis.com"
    "serviceusage.googleapis.com"
    "monitoring.googleapis.com"
    "logging.googleapis.com"
    "clouderrorreporting.googleapis.com"
    "iap.googleapis.com"
)

for API in "${REQUIRED_APIS[@]}"; do
    gcloud services enable ${API}
done

echo "Enumerating default service account email address"
GCP_DEFAULT_SERVICE_ACCOUNT=$(gcloud iam service-accounts list \
    --format="value(email)" \
    --filter="displayName:'Compute Engine default service account'")
echo "export TF_VAR_GCP_DEFAULT_SERVICE_ACCOUNT=\"$GCP_DEFAULT_SERVICE_ACCOUNT\"" >> gcloud.env

echo "Creating a bucket for storing remote TFSTATE"
TF_STATE_BUCKET=${TF_VAR_project}-tfstate
gsutil mb -p ${TF_VAR_project} gs://${TF_STATE_BUCKET}

# Create IAM policy for the state bucket
cat > iam.txt << EOF
{
  "bindings": [
    {
      "members": [
        "projectOwner:${TF_VAR_project}"
      ],
      "role": "roles/storage.legacyBucketOwner"
    },
    {
      "members": [
        "projectViewer:${TF_VAR_project}"
      ],
      "role": "roles/storage.legacyBucketReader"
    },
    {
      "members": [
        "${TERRAFORM_SA}"
      ],
      "role": "roles/storage.objectCreator"
    },
    {
      "members": [
        "${TERRAFORM_SA}"
      ],
      "role": "roles/storage.objectViewer"
    }
  ],
  "version": "1"
}
EOF

# Apply the IAM policy to the state bucket
gsutil iam set iam.txt gs://${TF_STATE_BUCKET}

# Create Terraform backend configuration
cat > backend.tf << EOF
terraform {
 backend "gcs" {
   bucket  = "${TF_STATE_BUCKET}"
   prefix  = "terraform/state"
 }
}
EOF

echo "Enabling versioning on the state bucket for safety"
gsutil versioning set on gs://${TF_STATE_BUCKET}

echo "Initializing terraform"
$TERRAFORM_CMD init

echo "Don't forget to 'source gcloud.env' before using Terraform!"
echo "A dynamically named service account was created that Terraform needs to know about"
