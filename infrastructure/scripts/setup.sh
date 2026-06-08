#!/bin/bash

# ==============================================================================
# This script configures the central Terraform state bucket,
# the environment-bound Service Accounts, and the Workload 
# Identity Federation (WIF) pools for GitHub Actions.
# ==============================================================================

# Exit immediately if a command exits with a non-zero status
set -e

echo "Starting Hub-and-Spoke Bootstrap..."

# ------------------------------------------------------------------------------
# 1. Variable Definitions
# ------------------------------------------------------------------------------
# NOTE: Using 'emilio-flores-portfolio' as the Hub based on previous verification.
export HUB_PROJECT="emilio-flores-portfolio"
export DEV_PROJECT="emilio-flores-portfolio-dev"
export PROD_PROJECT="emilio-flores-portfolio-prod"

export REPO_NAME="EmilioFC99/gcp-end-to-end-data-pipeline"
export POOL_NAME="github-actions-pool"
export PROVIDER_NAME="github-provider"
export DEV_STATE_BUCKET="tf-state-emilio-flores-dev"
export PROD_STATE_BUCKET="tf-state-emilio-flores-prod"

export DEV_SA_NAME="tf-dev-sa"
export PROD_SA_NAME="tf-prod-sa"
export DEV_SA="${DEV_SA_NAME}@${HUB_PROJECT}.iam.gserviceaccount.com"
export PROD_SA="${PROD_SA_NAME}@${HUB_PROJECT}.iam.gserviceaccount.com"

echo "Setting active gcloud project to Hub: ${HUB_PROJECT}"
gcloud config set project $HUB_PROJECT

# ------------------------------------------------------------------------------
# 2. Enable Required APIs
# ------------------------------------------------------------------------------
echo "Enabling IAM Credentials and STS APIs..."
gcloud services enable iamcredentials.googleapis.com sts.googleapis.com

# ------------------------------------------------------------------------------
# 3. Isolated Terraform State Buckets
# ------------------------------------------------------------------------------
echo "Configuring Isolated State Buckets..."

# Create Dev Bucket
if ! gcloud storage buckets describe gs://$DEV_STATE_BUCKET >/dev/null 2>&1; then
    gcloud storage buckets create gs://$DEV_STATE_BUCKET --location=us-central1 --uniform-bucket-level-access
    gcloud storage buckets update gs://$DEV_STATE_BUCKET --versioning
    gcloud storage buckets update gs://$DEV_STATE_BUCKET --update-labels=environment=dev,workload=devops-hub,component=terraform
fi

# Create Prod Bucket
if ! gcloud storage buckets describe gs://$PROD_STATE_BUCKET >/dev/null 2>&1; then
    gcloud storage buckets create gs://$PROD_STATE_BUCKET --location=us-central1 --uniform-bucket-level-access
    gcloud storage buckets update gs://$PROD_STATE_BUCKET --versioning
    gcloud storage buckets update gs://$PROD_STATE_BUCKET --update-labels=environment=prod,workload=devops-hub,component=terraform
fi

# ------------------------------------------------------------------------------
# 4. Service Accounts
# ------------------------------------------------------------------------------
echo "Provisioning Environment-Bound Service Accounts..."

if ! gcloud iam service-accounts describe $DEV_SA >/dev/null 2>&1; then
    gcloud iam service-accounts create $DEV_SA_NAME --display-name="Terraform Dev Environment SA"
fi

if ! gcloud iam service-accounts describe $PROD_SA >/dev/null 2>&1; then
    gcloud iam service-accounts create $PROD_SA_NAME --display-name="Terraform Prod Environment SA"
fi

echo "Granting State Bucket Access..."
# Dev SA only gets access to Dev Bucket
gcloud storage buckets add-iam-policy-binding gs://$DEV_STATE_BUCKET \
    --member="serviceAccount:$DEV_SA" \
    --role="roles/storage.objectAdmin"

# Prod SA only gets access to Prod Bucket
gcloud storage buckets add-iam-policy-binding gs://$PROD_STATE_BUCKET \
    --member="serviceAccount:$PROD_SA" \
    --role="roles/storage.objectAdmin"

echo "Granting Spoke Project Access..."
gcloud projects add-iam-policy-binding $DEV_PROJECT \
    --member="serviceAccount:$DEV_SA" \
    --role="roles/editor"

gcloud projects add-iam-policy-binding $PROD_PROJECT \
    --member="serviceAccount:$PROD_SA" \
    --role="roles/editor"

# ------------------------------------------------------------------------------
# 5. Workload Identity Federation
# ------------------------------------------------------------------------------
echo "Configuring Workload Identity Federation..."

# Create Pool if it doesn't exist
if ! gcloud iam workload-identity-pools describe $POOL_NAME --location="global" >/dev/null 2>&1; then
    gcloud iam workload-identity-pools create $POOL_NAME \
        --location="global" \
        --display-name="GitHub Actions Pool"
fi

# Create Provider if it doesn't exist
if ! gcloud iam workload-identity-pools providers describe $PROVIDER_NAME --location="global" --workload-identity-pool=$POOL_NAME >/dev/null 2>&1; then
    gcloud iam workload-identity-pools providers create-oidc $PROVIDER_NAME \
        --location="global" \
        --workload-identity-pool=$POOL_NAME \
        --issuer-uri="https://token.actions.githubusercontent.com" \
        --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.environment=assertion.environment" \
        --attribute-condition="assertion.repository == '${REPO_NAME}'"
else
    # Update existing provider to ensure attribute mapping and conditions are correct
    gcloud iam workload-identity-pools providers update-oidc $PROVIDER_NAME \
        --location="global" \
        --workload-identity-pool=$POOL_NAME \
        --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.environment=assertion.environment" \
        --attribute-condition="assertion.repository == '${REPO_NAME}'"
fi

export HUB_NUMBER=$(gcloud projects describe $HUB_PROJECT --format='value(projectNumber)')

echo "Binding Identities to GitHub Environments..."
# Dev Binding
gcloud iam service-accounts add-iam-policy-binding $DEV_SA \
    --role="roles/iam.workloadIdentityUser" \
    --member="principalSet://iam.googleapis.com/projects/${HUB_NUMBER}/locations/global/workloadIdentityPools/${POOL_NAME}/attribute.environment/development"

# Prod Binding
gcloud iam service-accounts add-iam-policy-binding $PROD_SA \
    --role="roles/iam.workloadIdentityUser" \
    --member="principalSet://iam.googleapis.com/projects/${HUB_NUMBER}/locations/global/workloadIdentityPools/${POOL_NAME}/attribute.environment/production"

# ------------------------------------------------------------------------------
# 6. Output Target Variables
# ------------------------------------------------------------------------------
echo "========================================================================"
echo "BOOTSTRAP COMPLETE!"
echo "========================================================================"
echo "Add the following Repository Variable in GitHub Actions (GCP_WORKLOAD_IDENTITY_PROVIDER):"
gcloud iam workload-identity-pools providers describe $PROVIDER_NAME \
    --location="global" \
    --workload-identity-pool=$POOL_NAME \
    --format="value(name)"
echo "------------------------------------------------------------------------"
echo "Add to GitHub 'development' Environment Secrets/Vars (TF_GCP_SERVICE_ACCOUNT):"
echo "$DEV_SA"
echo "------------------------------------------------------------------------"
echo "Add to GitHub 'production' Environment Secrets/Vars (TF_GCP_SERVICE_ACCOUNT):"
echo "$PROD_SA"
echo "========================================================================"