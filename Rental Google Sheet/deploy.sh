#!/bin/bash
set -e

REGION="asia-south1"
FUNCTION_NAME="sync-rental-sheets-live"
JOB_NAME="sync-rental-sheets-30m"

echo "Deploying $FUNCTION_NAME to $REGION from GitHub repository..."
gcloud functions deploy $FUNCTION_NAME \
    --gen2 \
    --runtime=python311 \
    --region=$REGION \
    --source=. \
    --entry-point=sync_rental_sheets_http \
    --trigger-http \
    --allow-unauthenticated \
    --memory=512MB \
    --timeout=180s

echo "Retrieving Function URL..."
FUNCTION_URL=$(gcloud functions describe $FUNCTION_NAME --gen2 --region=$REGION --format='value(serviceConfig.uri)')
echo "Function URL: $FUNCTION_URL"

echo "Configuring Cloud Scheduler job: $JOB_NAME..."
gcloud scheduler jobs delete $JOB_NAME --location=$REGION --quiet || true
gcloud scheduler jobs create http $JOB_NAME \
    --location=$REGION \
    --schedule="*/30 * * * *" \
    --time-zone="Asia/Kolkata" \
    --uri="$FUNCTION_URL" \
    --http-method=POST

echo "Triggering initial test run..."
gcloud scheduler jobs run $JOB_NAME --location=$REGION
echo "Deployment and scheduling complete!"
