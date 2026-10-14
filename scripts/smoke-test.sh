#!/usr/bin/env bash
# End-to-end test of a deployed stack:
#   API -> presigned upload -> S3 -> SQS -> Lambda -> DynamoDB -> API
# Needs: terraform state in ./terraform, AWS CLI, curl, jq.
#   ./scripts/smoke-test.sh                          # uploads samples/sample.png
#   ./scripts/smoke-test.sh samples/not-an-image.png # shows a rejected upload
set -euo pipefail

FILE="${1:-samples/sample.png}"
case "${FILE,,}" in
  *.png)          CONTENT_TYPE="image/png" ;;
  *.jpg|*.jpeg)   CONTENT_TYPE="image/jpeg" ;;
  *.webp)         CONTENT_TYPE="image/webp" ;;
  *.gif)          CONTENT_TYPE="image/gif" ;;
  *) echo "Unsupported file type: ${FILE}"; exit 2 ;;
esac

API_URL="$(terraform -chdir=terraform output -raw api_base_url)"
KEY_ID="$(terraform -chdir=terraform output -raw api_key_id)"
API_KEY="$(aws apigateway get-api-key --api-key "${KEY_ID}" --include-value --query value --output text)"

echo ">>> 1. Request an upload URL"
RESPONSE="$(curl -fsS -X POST "${API_URL}/uploads" \
  -H "x-api-key: ${API_KEY}" -H "Content-Type: application/json" \
  -d "{\"filename\": \"$(basename "${FILE}")\", \"content_type\": \"${CONTENT_TYPE}\"}")"
IMAGE_ID="$(jq -r '.image_id' <<<"${RESPONSE}")"
UPLOAD_URL="$(jq -r '.upload.url' <<<"${RESPONSE}")"
echo "image_id: ${IMAGE_ID}"

echo ">>> 2. Upload the file straight to S3 with the presigned POST"
FORM=()
while IFS= read -r field; do FORM+=(-F "${field}"); done \
  < <(jq -r '.upload.fields | to_entries[] | "\(.key)=\(.value)"' <<<"${RESPONSE}")
curl -fsS -o /dev/null -w "S3 responded with HTTP %{http_code}\n" -X POST "${UPLOAD_URL}" "${FORM[@]}" -F "file=@${FILE}"

echo ">>> 3. Wait for the pipeline to process it"
for attempt in $(seq 1 30); do
  STATUS="$(curl -s -o /tmp/image.json -w '%{http_code}' "${API_URL}/images/${IMAGE_ID}" -H "x-api-key: ${API_KEY}")"
  if [ "${STATUS}" = "200" ]; then
    echo "Processed after about $((attempt * 2)) seconds:"
    jq . /tmp/image.json
    exit 0
  fi
  sleep 2
done

echo "Not processed after 60 seconds. Check the alarms, the dead-letter queue and the Lambda logs."
exit 1
