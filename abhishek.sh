#!/bin/bash
set -e

# =====================================================
# GSP367 - Automate Data Capture at Scale with Document AI
# OFFICIAL LOCATIONS (as per course)
# =====================================================

FUNCTION_REGION="us-central1"
PROCESSOR_LOCATION="us"
BQ_LOCATION="US"

PROCESSOR_NAME="finance-processor"
FUNCTION_NAME="process-invoices"

PROJECT_ID=$(gcloud config get-value project)
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")

INPUT_BUCKET="${PROJECT_ID}-input-invoices"
OUTPUT_BUCKET="${PROJECT_ID}-output-invoices"
ARCHIVE_BUCKET="${PROJECT_ID}-archived-invoices"

echo "======================================"
echo " PROJECT ID     : $PROJECT_ID"
echo " FUNCTION REGION: $FUNCTION_REGION"
echo " PROCESSOR LOC  : $PROCESSOR_LOCATION"
echo "======================================"

# ---------------- ENABLE APIS ----------------
echo "Enabling APIs..."
gcloud services enable \
  documentai.googleapis.com \
  cloudfunctions.googleapis.com \
  cloudbuild.googleapis.com \
  eventarc.googleapis.com \
  run.googleapis.com \
  artifactregistry.googleapis.com

sleep 15

# ---------------- DELETE OLD CLOUD FUNCTION ----------------
echo "Deleting old Cloud Function (if exists)..."
gcloud functions delete $FUNCTION_NAME \
  --gen2 \
  --region=$FUNCTION_REGION \
  --quiet || true

# ---------------- DELETE OLD DOCUMENT AI PROCESSORS ----------------
echo "Deleting old Document AI processors..."
PROCESSORS=$(curl -s \
  -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
  "https://documentai.googleapis.com/v1/projects/$PROJECT_ID/locations/$PROCESSOR_LOCATION/processors" | \
  grep '"name":' | sed -E 's/.*processors\/([^"]+)".*/\1/')

for PID in $PROCESSORS; do
  curl -s -X DELETE \
    -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
    "https://documentai.googleapis.com/v1/projects/$PROJECT_ID/locations/$PROCESSOR_LOCATION/processors/$PID"
done

sleep 10

# ---------------- DELETE OLD BUCKETS ----------------
echo "Deleting old buckets..."
gsutil -m rm -r gs://$INPUT_BUCKET || true
gsutil -m rm -r gs://$OUTPUT_BUCKET || true
gsutil -m rm -r gs://$ARCHIVE_BUCKET || true

# ---------------- DELETE BIGQUERY DATASET ----------------
echo "Deleting BigQuery dataset..."
bq rm -r -f ${PROJECT_ID}:invoice_parser_results || true

# ---------------- COPY LAB FILES ----------------
echo "Copying lab files..."
rm -rf ~/document-ai-challenge
mkdir -p ~/document-ai-challenge
gsutil -m cp -r gs://spls/gsp367/* ~/document-ai-challenge/

# ---------------- CREATE DOCUMENT AI PROCESSOR ----------------
echo "Creating Document AI processor..."
ACCESS_TOKEN=$(gcloud auth application-default print-access-token)

curl -s -X POST \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"display_name\": \"$PROCESSOR_NAME\",
    \"type\": \"FORM_PARSER_PROCESSOR\"
  }" \
  "https://documentai.googleapis.com/v1/projects/$PROJECT_ID/locations/$PROCESSOR_LOCATION/processors"

sleep 10

# ---------------- GET PROCESSOR ID ----------------
PROCESSOR_ID=$(curl -s \
  -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
  "https://documentai.googleapis.com/v1/projects/$PROJECT_ID/locations/$PROCESSOR_LOCATION/processors" | \
  grep '"name":' | sed -E 's/.*processors\/([^"]+)".*/\1/' | head -n 1)

echo "PROCESSOR ID: $PROCESSOR_ID"

# ---------------- CREATE BUCKETS (US) ----------------
echo "Creating buckets..."
gsutil mb -c standard -l us gs://$INPUT_BUCKET
gsutil mb -c standard -l us gs://$OUTPUT_BUCKET
gsutil mb -c standard -l us gs://$ARCHIVE_BUCKET

# ---------------- BIGQUERY ----------------
echo "Creating BigQuery dataset & table..."
bq --location=$BQ_LOCATION mk -d invoice_parser_results

cd ~/document-ai-challenge/scripts/table-schema
bq mk --table invoice_parser_results.doc_ai_extracted_entities doc_ai_extracted_entities.json

# ---------------- DEPLOY CLOUD FUNCTION ----------------
echo "Deploying Cloud Function..."
cd ~/document-ai-challenge/scripts

gcloud functions deploy $FUNCTION_NAME \
  --gen2 \
  --region=$FUNCTION_REGION \
  --runtime=python310 \
  --entry-point=process_invoice \
  --source=cloud-functions/process-invoices \
  --timeout=400 \
  --trigger-bucket=$INPUT_BUCKET \
  --service-account=${PROJECT_ID}@appspot.gserviceaccount.com \
  --update-env-vars=PROCESSOR_ID=$PROCESSOR_ID,PARSER_LOCATION=$PROCESSOR_LOCATION,PROJECT_ID=$PROJECT_ID

# ---------------- UPLOAD SAMPLE FILES ----------------
echo "Uploading sample invoices..."
gsutil -m cp -r \
  gs://cloud-training/gsp367/invoices/* \
  gs://$INPUT_BUCKET/

echo "======================================"
echo " ✅ LAB SETUP COMPLETED (CLEAN RUN)"
echo "======================================"
