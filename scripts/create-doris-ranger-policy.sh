#!/bin/bash
# Script to create a Ranger policy for Apache Doris using REST API
# This script creates a policy allowing analyst1 to access test.table1

set -e

RANGER_URL="${RANGER_URL:-http://localhost:6080}"
RANGER_USER="${RANGER_USER:-admin}"
RANGER_PASSWORD="${RANGER_PASSWORD:-admin}"
SERVICE_NAME="${SERVICE_NAME:-doris_nbd}"

# Policy configuration
POLICY_NAME="analyst1-test-table1-access"
USER_NAME="analyst1"
DATABASE_NAME="test"
TABLE_NAME="table1"
CATALOG_NAME="internal"

echo "Creating Ranger policy for Apache Doris..."
echo "Service: $SERVICE_NAME"
echo "Policy: $POLICY_NAME"
echo "User: $USER_NAME"
echo "Resource: $CATALOG_NAME.$DATABASE_NAME.$TABLE_NAME"

# Create policy JSON
POLICY_JSON=$(cat <<EOF
{
  "service": "$SERVICE_NAME",
  "name": "$POLICY_NAME",
  "policyType": 0,
  "description": "Allow $USER_NAME to access $DATABASE_NAME database $TABLE_NAME table",
  "resources": {
    "catalog": {
      "values": ["$CATALOG_NAME"],
      "isExcludes": false,
      "isRecursive": false
    },
    "database": {
      "values": ["$DATABASE_NAME"],
      "isExcludes": false,
      "isRecursive": false
    },
    "table": {
      "values": ["$TABLE_NAME"],
      "isExcludes": false,
      "isRecursive": false
    }
  },
  "policyItems": [
    {
      "accesses": [
        {
          "type": "SELECT",
          "isAllowed": true
        },
        {
          "type": "SHOW",
          "isAllowed": true
        }
      ],
      "users": ["$USER_NAME"],
      "groups": [],
      "roles": [],
      "conditions": [],
      "delegateAdmin": false
    }
  ],
  "denyPolicyItems": [],
  "allowExceptions": [],
  "denyExceptions": [],
  "dataMaskPolicyItems": [],
  "rowFilterPolicyItems": [],
  "id": 0,
  "guid": "",
  "isEnabled": true,
  "version": 1,
  "serviceType": "doris",
  "options": {},
  "validitySchedules": [],
  "policyPriority": 0,
  "zoneName": "",
  "isAuditEnabled": true
}
EOF
)

# Create the policy
echo "Sending policy creation request to Ranger..."
RESPONSE=$(curl -s -u "$RANGER_USER:$RANGER_PASSWORD" \
  -X POST \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  "$RANGER_URL/service/public/v2/api/policy" \
  -d "$POLICY_JSON")

# Check if policy was created successfully
if echo "$RESPONSE" | grep -q '"id"'; then
    POLICY_ID=$(echo "$RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('id', 'unknown'))" 2>/dev/null || echo "unknown")
    echo "✓ Policy created successfully!"
    echo "  Policy ID: $POLICY_ID"
    echo "  Policy Name: $POLICY_NAME"
    echo ""
    echo "Policy details:"
    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
else
    echo "✗ Failed to create policy"
    echo "Response: $RESPONSE"
    exit 1
fi

# Verify the policy
echo ""
echo "Verifying policy..."
VERIFY_RESPONSE=$(curl -s -u "$RANGER_USER:$RANGER_PASSWORD" \
  "$RANGER_URL/service/public/v2/api/policy?serviceName=$SERVICE_NAME&policyName=$POLICY_NAME")

if echo "$VERIFY_RESPONSE" | grep -q "$POLICY_NAME"; then
    echo "✓ Policy verified successfully!"
    echo ""
    echo "Policy can be viewed at:"
    echo "  $RANGER_URL/service/plugins/policies/editPolicy.html?serviceId=1&policyId=$POLICY_ID"
else
    echo "⚠ Warning: Could not verify policy (it may still be created)"
fi

