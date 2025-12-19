#!/bin/bash
set -e

# =====================================================
# Automate Data Capture at Scale with Document AI
# GSP367 | Qwiklabs Compatible
# =====================================================

REGION="us"
PROCESSOR_NAME="finance-processor"

echo "======================================"
echo " REGION        : $REGION"
echo " PROCESSOR     : $PROCESSOR_NAME"
echo "======================================"

PROJECT_ID=$(gcloud config get-value project)
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")

echo " PROJECT ID    : $PROJECT_ID"
echo " PROJECT NUM   : $PROJECT_NUMBER"
echo "======================================"

# ---------------- ENABLE REQUIRED APIS ----------------
echo "Enabling APIs..."
gcloud services enable \
  documentai.googleapis.com \
  cloudfunctions.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  eventarc.googleapis.com \
  run.googleapis.com

sleep 20

# ---------------- COPY LAB FILES ----------------
echo "Copying lab files..."
mkdir -p ~/document-ai-challenge
gsutil -m cp -r gs://spls/gsp367/* ~/document-ai-challenge/

# ---------------- CREATE DOCUMENT AI PROCESSOR (US) ----------------
echo "Creating Document AI processor (US)..."
ACCESS_TOKEN=$(gcloud auth application-default print-access-token)

curl -s -X POST \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"display_name\": \"$PROCESSOR_NAME\",
    \"type\": \"FORM_PARSER_PROCESSOR\"
  }" \
  "https://documentai.googleapis.com/v1/projects/$PROJECT_ID/locations/us/processors" || true

sleep 10

# ---------------- GET PROCESSOR ID ----------------
echo "Fetching Processor ID..."
PROCESSOR_ID=$(curl -s -X GET \
  -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
  "https://documentai.googleapis.com/v1/projects/$PROJECT_ID/locations/us/processors" | \
  grep '"name":' | sed -E 's/.*processors\/([^"]+)".*/\1/' | head -n 1)

echo "PROCESSOR_ID  : $PROCESSOR_ID"

# ---------------- CREATE CLOUD STORAGE BUCKETS ----------------
echo "Creating Cloud Storage buckets..."
gsutil mb -c standard -l $REGION gs://${PROJECT_ID}-input-invoices || true
gsutil mb -c standard -l $REGION gs://${PROJECT_ID}-output-invoices || true
gsutil mb -c standard -l $REGION gs://${PROJECT_ID}-archived-invoices || true

# ---------------- BIGQUERY SETUP ----------------
echo "Setting up BigQuery..."
bq --location=EU mk -d \
  --description "Form Parser Results" \
  ${PROJECT_ID}:invoice_parser_results || true

cd ~/document-ai-challenge/scripts/table-schema

bq mk --table \
  invoice_parser_results.doc_ai_extracted_entities \
  doc_ai_extracted_entities.json || true

# ---------------- IAM PERMISSIONS ----------------
echo "Setting IAM permissions..."
SERVICE_ACCOUNT=$(gcloud storage service-agent --project=$PROJECT_ID)

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${SERVICE_ACCOUNT}" \
  --role="roles/pubsub.publisher" || true

sleep 20

# ---------------- DEPLOY CLOUD FUNCTION ----------------
echo "Deploying Cloud Function..."
cd ~/document-ai-challenge/scripts

gcloud functions deploy process-invoices \
  --gen2 \
  --region=$REGION \
  --runtime=python310 \
  --entry-point=process_invoice \
  --source=cloud-functions/process-invoices \
  --timeout=400 \
  --trigger-bucket=${PROJECT_ID}-input-invoices \
  --service-account=${PROJECT_ID}@appspot.gserviceaccount.com \
  --update-env-vars=PROCESSOR_ID=${PROCESSOR_ID},PARSER_LOCATION=us,PROJECT_ID=${PROJECT_ID}

# ---------------- UPLOAD SAMPLE INVOICES ----------------
echo "Uploading sample invoices..."
gsutil -m cp -r \
  gs://cloud-training/gsp367/invoices/* \
  gs://${PROJECT_ID}-input-invoices/

echo "======================================"
echo " ✅ LAB SETUP COMPLETED SUCCESSFULLY"
echo "======================================"
