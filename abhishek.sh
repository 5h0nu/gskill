# Set text styles
YELLOW=$(tput setaf 3)
BOLD=$(tput bold)
RESET=$(tput sgr0)

echo "Please set the below values correctly"
read -p "${YELLOW}${BOLD}Enter the REGION (europe-west1): ${RESET}" REGION
read -p "${YELLOW}${BOLD}Enter the PROCESSOR NAME: ${RESET}" PROCESSOR

export REGION PROCESSOR

gcloud auth list

export PROJECT_ID=$(gcloud config get-value project)
export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")

# Enable APIs
gcloud services enable \
  documentai.googleapis.com \
  cloudfunctions.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com

sleep 15

# Copy lab files
mkdir -p ~/document-ai-challenge
gsutil -m cp -r gs://spls/gsp367/* ~/document-ai-challenge/

# Create Document AI processor (EU)
ACCESS_CP=$(gcloud auth application-default print-access-token)

curl -X POST \
  -H "Authorization: Bearer $ACCESS_CP" \
  -H "Content-Type: application/json" \
  -d '{
    "display_name": "'"$PROCESSOR"'",
    "type": "FORM_PARSER_PROCESSOR"
  }' \
  "https://documentai.googleapis.com/v1/projects/$PROJECT_ID/locations/eu/processors"

# Create buckets (EUROPE-WEST1)
gsutil mb -c standard -l europe-west1 gs://${PROJECT_ID}-input-invoices
gsutil mb -c standard -l europe-west1 gs://${PROJECT_ID}-output-invoices
gsutil mb -c standard -l europe-west1 gs://${PROJECT_ID}-archived-invoices

# Create BigQuery dataset (EU)
bq --location=EU mk -d \
  --description "Form Parser Results" \
  ${PROJECT_ID}:invoice_parser_results

cd ~/document-ai-challenge/scripts/table-schema

bq mk --table \
  invoice_parser_results.doc_ai_extracted_entities \
  doc_ai_extracted_entities.json

# IAM for Storage
SERVICE_ACCOUNT=$(gcloud storage service-agent --project=$PROJECT_ID)

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${SERVICE_ACCOUNT}" \
  --role="roles/pubsub.publisher"

sleep 20

# Get Processor ID (EU)
PROCESSOR_ID=$(curl -X GET \
  -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
  -H "Content-Type: application/json" \
  "https://documentai.googleapis.com/v1/projects/$PROJECT_ID/locations/eu/processors" | \
  grep '"name":' | \
  sed -E 's/.*processors\/([^"]+)".*/\1/')

export PROCESSOR_ID

# Deploy Cloud Function (EUROPE-WEST1)
gcloud functions deploy process-invoices \
  --gen2 \
  --region=europe-west1 \
  --runtime=python310 \
  --entry-point=process_invoice \
  --source=cloud-functions/process-invoices \
  --timeout=400 \
  --trigger-bucket=${PROJECT_ID}-input-invoices \
  --service-account=${PROJECT_ID}@appspot.gserviceaccount.com \
  --update-env-vars=PROCESSOR_ID=${PROCESSOR_ID},PARSER_LOCATION=eu,PROJECT_ID=${PROJECT_ID}

# Upload sample invoices
gsutil -m cp -r \
  gs://cloud-training/gsp367/* \
  gs://${PROJECT_ID}-input-invoices/
