#!/bin/bash
set -e

# =====================================================
# GSP367 – Document AI + Cloud Functions (EU version)
# Document AI: us (MANDATORY for Qwiklabs)
# Cloud Functions & Buckets: europe-west1
# =====================================================

REGION="europe-west1"
PROCESSOR_NAME="finance-processor"

echo "REGION: $REGION"
echo "PROCESSOR: $PROCESSOR_NAME"

PROJECT_ID=$(gcloud config get-value project)
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")

echo "PROJECT_ID: $PROJECT_ID"
echo "PROJECT_NUMBER: $PROJECT_NUMBER"

# ---------------- ENABLE APIS ----------------
gcloud services enable \
  documentai.googleapis.com \
  cloudfunctions.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  eventarc.googleapis.com \
  run.googleapis.com

sleep 20

# ---------------- COPY LAB FILES ----------------
mkdir -p ~/document-ai-challenge
gsutil -m cp -r gs://spls/gsp367/* ~/document-ai-challenge/

# ---------------- CREATE DOCUMENT AI PROCESSOR (US) ----------------
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
PROCESSOR_ID=$(curl -s -X GET \
  -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
  "https://documentai.googleapis.com/v1/projects/$PROJECT_ID/locations/us/processors" | \
  grep '"name":' | sed -E 's/.*processors\/([^"]+)".*/\1/' | head -n 1)

echo "PROCESSOR_ID: $PROCESSOR_ID"

# ---------------- CREATE BUCKETS (EU) ----------------
gsutil mb -c standard -l $REGION gs://${PROJECT_ID}-input-invoices || true
gsutil mb -c standard -l $REGION gs://${PROJECT_ID}-output-invoices || true
gsutil mb -c standard -l $REGION gs://${PROJECT_ID}-archived-invoices || true

# ---------------- BIGQUERY ----------------
bq --location=EU mk -d \
  --description "Form Parser Results" \
  ${PROJECT_ID}:invoice_parser_results || true

cd ~/document-ai-challenge/scripts/table-schema

bq mk --table \
  invoice_parser_results.doc_ai_extracted_entities \
  doc_ai_extracted_entities.json || true

# ---------------- IAM ----------------
SERVICE_ACCOUNT=$(gcloud storage service-agent --project=$PROJECT_ID)

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${SERVICE_ACCOUNT}" \
  --role="roles/pubsub.publisher" || true

sleep 20

# ---------------- DEPLOY CLOUD FUNCTION (EU) ----------------
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

# ---------------- UPLOAD SAMPLE FILES ----------------
gsutil -m cp -r \
  gs://cloud-training/gsp367/invoices/* \
  gs://${PROJECT_ID}-input-invoices/

echo "✅ GSP367 SETUP COMPLETED SUCCESSFULLY"
