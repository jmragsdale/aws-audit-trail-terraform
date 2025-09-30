#!/bin/bash

API_ENDPOINT=$(terraform output -raw api_endpoint 2>/dev/null)

if [ -z "$API_ENDPOINT" ]; then
    echo "❌ Error: Run terraform apply first"
    exit 1
fi

ACCOUNT_ID="ACC-TEST-$(date +%s)"

echo "🧪 Testing Immutable Audit Trail"
echo "Account: $ACCOUNT_ID"
echo ""

echo "1️⃣ Creating transaction 1..."
curl -s -X POST $API_ENDPOINT/audit \
  -H 'Content-Type: application/json' \
  -d "{
    \"transactionId\": \"TXN-001\",
    \"accountId\": \"$ACCOUNT_ID\",
    \"amount\": 1000.00,
    \"type\": \"CREDIT\",
    \"description\": \"Initial deposit\"
  }" | python3 -m json.tool

sleep 2

echo ""
echo "2️⃣ Creating transaction 2..."
curl -s -X POST $API_ENDPOINT/audit \
  -H 'Content-Type: application/json' \
  -d "{
    \"transactionId\": \"TXN-002\",
    \"accountId\": \"$ACCOUNT_ID\",
    \"amount\": 250.50,
    \"type\": \"DEBIT\",
    \"description\": \"Purchase\"
  }" | python3 -m json.tool

sleep 2

echo ""
echo "3️⃣ Verifying chain..."
curl -s $API_ENDPOINT/audit/$ACCOUNT_ID/verify | python3 -m json.tool

echo ""
echo "✅ Test complete!"
