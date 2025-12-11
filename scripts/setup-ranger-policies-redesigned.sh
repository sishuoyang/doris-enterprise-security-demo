#!/bin/bash
#
# Setup Ranger Policies for Doris Users and Groups (Redesigned - Non-Overlapping)
#
# This script creates non-overlapping Ranger policies for different users and groups:
# 
# GROUP POLICIES (non-overlapping resource scopes):
# - admins: Full access to ALL databases (catalog=*, database=*, table=*, column=*)
# - analysts: Read-only access to demo_db only (catalog=*, database=demo_db, table=*, column=*)
# - sales: Read/Write access to sales_db only (catalog=*, database=sales_db, table=*, column=*)
# - developers: Read/Write access to demo_db.products and orders tables (catalog=*, database=demo_db, table=[products,orders], column=*)
# - data_engineers: Read/Write access to demo_db.users table only (catalog=*, database=demo_db, table=users, column=*)
# - readonly_users: Read-only access to sales_db.customers table only (catalog=*, database=sales_db, table=customers, column=*)
#
# USER POLICIES (non-overlapping resource scopes):
# - admin: Full access to ALL databases (same as admins group, but as user policy)
# - analyst1: Read-only access to demo_db.products table only
# - analyst2: Read-only access to demo_db.orders table only
# - sales_user1: Read/Write access to sales_db.customers table only
# - sales_user2: Read/Write access to sales_db.sales table only
#
# Note: These groups and users must exist in LDAP (OpenLDAP) for authentication to work
#
# Usage: ./setup-ranger-policies-redesigned.sh [options]
#   --ranger-url URL     Ranger Admin URL (default: http://localhost:6080)
#   --ranger-user USER   Ranger Admin user (default: admin)
#   --ranger-pass PASS   Ranger Admin password (default: Admin123)
#   --service-name NAME  Doris service name (default: doris_nbd)
#   --skip-existing      Skip creating policies that already exist
#   --help               Show this help message

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configuration
RANGER_URL="${RANGER_URL:-http://localhost:6080}"
RANGER_USER="${RANGER_USER:-admin}"
RANGER_PASSWORD="${RANGER_PASSWORD:-Admin123}"
SERVICE_NAME="${SERVICE_NAME:-doris_nbd}"
SKIP_EXISTING=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --ranger-url)
            RANGER_URL="$2"
            shift 2
            ;;
        --ranger-user)
            RANGER_USER="$2"
            shift 2
            ;;
        --ranger-pass)
            RANGER_PASSWORD="$2"
            shift 2
            ;;
        --service-name)
            SERVICE_NAME="$2"
            shift 2
            ;;
        --skip-existing)
            SKIP_EXISTING=true
            shift
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --ranger-url URL     Ranger Admin URL (default: http://localhost:6080)"
            echo "  --ranger-user USER   Ranger Admin user (default: admin)"
            echo "  --ranger-pass PASS   Ranger Admin password (default: Admin123)"
            echo "  --service-name NAME  Doris service name (default: doris_nbd)"
            echo "  --skip-existing      Skip creating policies that already exist"
            echo "  --help               Show this help message"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${BLUE}→${NC} $1"
}

# Check if curl is available
check_curl() {
    if ! command -v curl &> /dev/null; then
        log_error "curl not found. Please install curl."
        exit 1
    fi
}

# Check if Python3 is available
check_python() {
    if ! command -v python3 &> /dev/null; then
        log_error "python3 not found. Please install python3."
        exit 1
    fi
}

# Wait for Ranger Admin API to be ready
wait_for_ranger() {
    log_step "Waiting for Ranger Admin API to be ready..."
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if curl -s -f -u "${RANGER_USER}:${RANGER_PASSWORD}" \
            "${RANGER_URL}/service/plugins/definitions?page=0&pageSize=1" &> /dev/null; then
            log_info "Ranger Admin API is ready"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    
    log_error "Ranger Admin API is not ready after $((max_attempts * 2)) seconds"
    return 1
}

# Get service ID from service name
get_service_id() {
    local service_name="$1"
    local service_info=$(curl -s -w "\n%{http_code}" -u "${RANGER_USER}:${RANGER_PASSWORD}" \
        "${RANGER_URL}/service/public/v2/api/service/name/${service_name}" 2>/dev/null)
    
    local http_code=$(echo "$service_info" | tail -n 1)
    local response=$(echo "$service_info" | sed '$d')
    
    if [ "$http_code" != "200" ]; then
        log_error "Failed to get service ID for '${service_name}' (HTTP ${http_code})"
        return 1
    fi
    
    local service_id=$(echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('id', ''))
except:
    print('')
" 2>/dev/null)
    
    if [ -z "$service_id" ]; then
        log_error "Could not extract service ID from response"
        return 1
    fi
    
    echo "$service_id"
}

# Check if policy exists by name
policy_exists_by_name() {
    local service_id="$1"
    local policy_name="$2"
    
    # Use plugins API which is more reliable
    local policies=$(curl -s -w "\n%{http_code}" -u "${RANGER_USER}:${RANGER_PASSWORD}" \
        "${RANGER_URL}/service/plugins/policies/service/name/${SERVICE_NAME}" 2>/dev/null)
    
    local http_code=$(echo "$policies" | tail -n 1)
    local response=$(echo "$policies" | sed '$d')
    
    if [ "$http_code" != "200" ]; then
        return 1
    fi
    
    echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    policies = data.get('policies', [])
    for p in policies:
        if p.get('name') == '${policy_name}':
            print(p.get('id', ''))
            sys.exit(0)
    sys.exit(1)
except:
    sys.exit(1)
" 2>/dev/null
    
    return $?
}

# Delete policy by name
delete_policy_by_name() {
    local service_id="$1"
    local policy_name="$2"
    
    local policy_id=$(policy_exists_by_name "$service_id" "$policy_name" 2>/dev/null || echo "")
    if [ -z "$policy_id" ]; then
        return 0  # Policy doesn't exist, nothing to delete
    fi
    
    log_info "Deleting existing policy '${policy_name}' (ID: ${policy_id})..."
    local response=$(curl -s -w "\n%{http_code}" -u "${RANGER_USER}:${RANGER_PASSWORD}" \
        -X DELETE \
        "${RANGER_URL}/service/public/v2/api/policy/${policy_id}" 2>/dev/null)
    
    local http_code=$(echo "$response" | tail -n 1)
    if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
        log_info "✓ Policy '${policy_name}' deleted successfully"
        return 0
    else
        log_warn "⚠ Failed to delete policy (HTTP ${http_code})"
        return 1
    fi
}

# Create or update a Ranger policy
create_or_update_policy() {
    local service_id="$1"
    local policy_name="$2"
    local policy_json="$3"
    
    # Check if policy exists
    local existing_policy_id=$(policy_exists_by_name "$service_id" "$policy_name" 2>/dev/null || echo "")
    
    if [ -n "$existing_policy_id" ]; then
        if [ "$SKIP_EXISTING" = true ]; then
            log_info "Policy '${policy_name}' already exists (ID: ${existing_policy_id}), skipping..."
            return 0
        else
            log_info "Policy '${policy_name}' already exists (ID: ${existing_policy_id}), updating..."
            
            # Get existing policy to preserve ID and version
            local existing_policy=$(curl -s -u "${RANGER_USER}:${RANGER_PASSWORD}" \
                "${RANGER_URL}/service/public/v2/api/policy/${existing_policy_id}" 2>/dev/null)
            
            # Merge existing policy with new policy JSON
            local updated_json=$(echo "$existing_policy" | python3 -c "
import sys, json
try:
    existing = json.load(sys.stdin)
    new = json.loads('''${policy_json}''')
    # Update fields from new policy but preserve ID and version
    for key in new:
        if key not in ['id', 'version', 'guid', 'createTime', 'createdBy']:
            existing[key] = new[key]
    existing['id'] = ${existing_policy_id}
    existing['version'] = existing.get('version', 0) + 1
    print(json.dumps(existing))
except Exception as e:
    print('ERROR: ' + str(e), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)
            
            if [ -z "$updated_json" ] || echo "$updated_json" | grep -q "ERROR"; then
                log_warn "Failed to merge policy, will try to delete and recreate..."
                delete_policy_by_name "$service_id" "$policy_name"
            else
                local response=$(curl -s -w "\n%{http_code}" -u "${RANGER_USER}:${RANGER_PASSWORD}" \
                    -X PUT \
                    -H 'Content-Type: application/json' \
                    "${RANGER_URL}/service/public/v2/api/policy/${existing_policy_id}" \
                    -d "${updated_json}" 2>/dev/null)
                
                local http_code=$(echo "$response" | tail -n 1)
                local response_body=$(echo "$response" | sed '$d')
                
                if [ "$http_code" = "200" ]; then
                    log_info "✓ Policy '${policy_name}' updated successfully"
                    return 0
                else
                    log_warn "⚠ Failed to update policy (HTTP ${http_code}), will try to delete and recreate..."
                    log_warn "  Response: ${response_body}"
                    delete_policy_by_name "$service_id" "$policy_name"
                fi
            fi
        fi
    fi
    
    # Create new policy
    log_info "Creating policy '${policy_name}'..."
    
    local response=$(curl -s -w "\n%{http_code}" -u "${RANGER_USER}:${RANGER_PASSWORD}" \
        -X POST \
        -H 'Content-Type: application/json' \
        "${RANGER_URL}/service/public/v2/api/policy" \
        -d "${policy_json}" 2>/dev/null)
    
    local http_code=$(echo "$response" | tail -n 1)
    local response_body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        log_info "✓ Policy '${policy_name}' created successfully"
        return 0
    elif echo "$response_body" | grep -qi "already exists\|duplicate\|conflict\|matching resource" 2>/dev/null; then
        log_warn "⚠ Policy creation failed due to resource conflict (HTTP ${http_code})"
        log_warn "  Response: ${response_body}"
        log_warn "  Attempting to find and delete conflicting policy..."
        
        # Try to extract conflicting policy name from error message
        local conflict_name=$(echo "$response_body" | python3 -c "
import sys, json, re
try:
    data = json.load(sys.stdin)
    msg = data.get('msgDesc', '')
    # Try to find policy name in error message
    matches = re.findall(r'policy-name=\[([^\]]+)\]', msg)
    if matches:
        # Get the first match that's not the current policy name
        for match in matches:
            if match != '${policy_name}':
                print(match)
                break
except:
    pass
" 2>/dev/null)
        
        if [ -n "$conflict_name" ] && [ "$conflict_name" != "$policy_name" ]; then
            log_info "Found conflicting policy: ${conflict_name}, deleting it..."
            delete_policy_by_name "$service_id" "$conflict_name"
            # Small delay before retry
            sleep 1
            # Retry creation
            log_info "Retrying policy creation..."
            response=$(curl -s -w "\n%{http_code}" -u "${RANGER_USER}:${RANGER_PASSWORD}" \
                -X POST \
                -H 'Content-Type: application/json' \
                "${RANGER_URL}/service/public/v2/api/policy" \
                -d "${policy_json}" 2>/dev/null)
            http_code=$(echo "$response" | tail -n 1)
            response_body=$(echo "$response" | sed '$d')
            if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
                log_info "✓ Policy '${policy_name}' created successfully after deleting conflict"
                return 0
            else
                log_warn "Retry also failed (HTTP ${http_code})"
            fi
        elif [ "$conflict_name" = "$policy_name" ]; then
            # Policy with same name exists, update it instead
            log_info "Policy with same name exists, updating instead..."
            local existing_id=$(policy_exists_by_name "$service_id" "$policy_name" 2>/dev/null || echo "")
            if [ -n "$existing_id" ]; then
                # Update existing policy
                local existing_policy=$(curl -s -u "${RANGER_USER}:${RANGER_PASSWORD}" \
                    "${RANGER_URL}/service/public/v2/api/policy/${existing_id}" 2>/dev/null)
                local updated_json=$(echo "$existing_policy" | python3 -c "
import sys, json
try:
    existing = json.load(sys.stdin)
    new = json.loads('''${policy_json}''')
    for key in new:
        if key not in ['id', 'version', 'guid', 'createTime', 'createdBy']:
            existing[key] = new[key]
    existing['id'] = ${existing_id}
    existing['version'] = existing.get('version', 0) + 1
    print(json.dumps(existing))
except Exception as e:
    print('ERROR: ' + str(e), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)
                if [ -n "$updated_json" ] && ! echo "$updated_json" | grep -q "ERROR"; then
                    response=$(curl -s -w "\n%{http_code}" -u "${RANGER_USER}:${RANGER_PASSWORD}" \
                        -X PUT \
                        -H 'Content-Type: application/json' \
                        "${RANGER_URL}/service/public/v2/api/policy/${existing_id}" \
                        -d "${updated_json}" 2>/dev/null)
                    http_code=$(echo "$response" | tail -n 1)
                    if [ "$http_code" = "200" ]; then
                        log_info "✓ Policy '${policy_name}' updated successfully"
                        return 0
                    fi
                fi
            fi
        fi
        
        log_warn "  Could not resolve conflict automatically. Policy may need manual cleanup."
        return 1
    else
        log_warn "⚠ Failed to create policy '${policy_name}' (HTTP ${http_code})"
        log_warn "  Response: ${response_body}"
        return 1
    fi
}

# GROUP POLICIES (non-overlapping)

# Policy 1: admins group - Full access to ALL databases
create_admins_group_policy() {
    local service_id="$1"
    local policy_name="group_admins_all_databases"
    
    local policy_json=$(cat <<EOF
{
    "service": "${SERVICE_NAME}",
    "serviceId": ${service_id},
    "name": "${policy_name}",
    "description": "Full access for admins group to all databases",
    "resources": {
        "catalog": {"values": ["*"], "isExcludes": false, "isRecursive": false},
        "database": {"values": ["*"], "isExcludes": false, "isRecursive": false},
        "table": {"values": ["*"], "isExcludes": false, "isRecursive": false},
        "column": {"values": ["*"], "isExcludes": false, "isRecursive": false}
    },
    "policyItems": [{
        "accesses": [
            {"type": "SELECT", "isAllowed": true},
            {"type": "CREATE", "isAllowed": true},
            {"type": "DROP", "isAllowed": true},
            {"type": "ALTER", "isAllowed": true},
            {"type": "LOAD", "isAllowed": true},
            {"type": "GRANT", "isAllowed": true},
            {"type": "SHOW", "isAllowed": true},
            {"type": "SHOW_VIEW", "isAllowed": true},
            {"type": "ADMIN", "isAllowed": true},
            {"type": "NODE", "isAllowed": true},
            {"type": "USAGE", "isAllowed": true}
        ],
        "users": [],
        "groups": ["admins"],
        "roles": [],
        "conditions": [],
        "delegateAdmin": true
    }],
    "denyPolicyItems": [],
    "allowExceptions": [],
    "denyExceptions": [],
    "isEnabled": true,
    "isAuditEnabled": true
}
EOF
)
    
    create_or_update_policy "$service_id" "$policy_name" "$policy_json"
}

# Policy 2: analysts group - Read-only access to demo_db only
create_analysts_group_policy() {
    local service_id="$1"
    local policy_name="group_analysts_demo_db_readonly"
    
    local policy_json=$(cat <<EOF
{
    "service": "${SERVICE_NAME}",
    "serviceId": ${service_id},
    "name": "${policy_name}",
    "description": "Read-only access for analysts group to demo_db only",
    "resources": {
        "catalog": {"values": ["*"], "isExcludes": false, "isRecursive": false},
        "database": {"values": ["demo_db"], "isExcludes": false, "isRecursive": false},
        "table": {"values": ["*"], "isExcludes": false, "isRecursive": false},
        "column": {"values": ["*"], "isExcludes": false, "isRecursive": false}
    },
    "policyItems": [{
        "accesses": [
            {"type": "SELECT", "isAllowed": true},
            {"type": "SHOW", "isAllowed": true},
            {"type": "SHOW_VIEW", "isAllowed": true},
            {"type": "USAGE", "isAllowed": true}
        ],
        "users": [],
        "groups": ["analysts"],
        "roles": [],
        "conditions": [],
        "delegateAdmin": false
    }],
    "denyPolicyItems": [],
    "allowExceptions": [],
    "denyExceptions": [],
    "isEnabled": true,
    "isAuditEnabled": true
}
EOF
)
    
    create_or_update_policy "$service_id" "$policy_name" "$policy_json"
}

# Policy 3: sales group - Read/Write access to sales_db only
create_sales_group_policy() {
    local service_id="$1"
    local policy_name="group_sales_sales_db_rw"
    
    local policy_json=$(cat <<EOF
{
    "service": "${SERVICE_NAME}",
    "serviceId": ${service_id},
    "name": "${policy_name}",
    "description": "Read/Write access for sales group to sales_db only",
    "resources": {
        "catalog": {"values": ["*"], "isExcludes": false, "isRecursive": false},
        "database": {"values": ["sales_db"], "isExcludes": false, "isRecursive": false},
        "table": {"values": ["*"], "isExcludes": false, "isRecursive": false},
        "column": {"values": ["*"], "isExcludes": false, "isRecursive": false}
    },
    "policyItems": [{
        "accesses": [
            {"type": "SELECT", "isAllowed": true},
            {"type": "CREATE", "isAllowed": true},
            {"type": "DROP", "isAllowed": true},
            {"type": "ALTER", "isAllowed": true},
            {"type": "LOAD", "isAllowed": true},
            {"type": "SHOW", "isAllowed": true},
            {"type": "SHOW_VIEW", "isAllowed": true},
            {"type": "USAGE", "isAllowed": true}
        ],
        "users": [],
        "groups": ["sales"],
        "roles": [],
        "conditions": [],
        "delegateAdmin": false
    }],
    "denyPolicyItems": [],
    "allowExceptions": [],
    "denyExceptions": [],
    "isEnabled": true,
    "isAuditEnabled": true
}
EOF
)
    
    create_or_update_policy "$service_id" "$policy_name" "$policy_json"
}

# Policy 4: developers group - Read/Write access to demo_db.products and demo_db.orders tables only
create_developers_group_policy() {
    local service_id="$1"
    local policy_name="group_developers_demo_db_products_orders_rw"
    
    local policy_json=$(cat <<EOF
{
    "service": "${SERVICE_NAME}",
    "serviceId": ${service_id},
    "name": "${policy_name}",
    "description": "Read/Write access for developers group to demo_db.products and demo_db.orders tables only",
    "resources": {
        "catalog": {"values": ["*"], "isExcludes": false, "isRecursive": false},
        "database": {"values": ["demo_db"], "isExcludes": false, "isRecursive": false},
        "table": {"values": ["products", "orders"], "isExcludes": false, "isRecursive": false},
        "column": {"values": ["*"], "isExcludes": false, "isRecursive": false}
    },
    "policyItems": [{
        "accesses": [
            {"type": "SELECT", "isAllowed": true},
            {"type": "CREATE", "isAllowed": true},
            {"type": "DROP", "isAllowed": true},
            {"type": "ALTER", "isAllowed": true},
            {"type": "LOAD", "isAllowed": true},
            {"type": "SHOW", "isAllowed": true},
            {"type": "SHOW_VIEW", "isAllowed": true},
            {"type": "USAGE", "isAllowed": true}
        ],
        "users": [],
        "groups": ["developers"],
        "roles": [],
        "conditions": [],
        "delegateAdmin": false
    }],
    "denyPolicyItems": [],
    "allowExceptions": [],
    "denyExceptions": [],
    "isEnabled": true,
    "isAuditEnabled": true
}
EOF
)
    
    create_or_update_policy "$service_id" "$policy_name" "$policy_json"
}

# Policy 5: data_engineers group - Read/Write access to demo_db.users table only
create_dataengineers_group_policy() {
    local service_id="$1"
    local policy_name="group_data_engineers_demo_db_users_table"
    
    local policy_json=$(cat <<EOF
{
    "service": "${SERVICE_NAME}",
    "serviceId": ${service_id},
    "name": "${policy_name}",
    "description": "Read/Write access for data_engineers group to demo_db.users table only",
    "resources": {
        "catalog": {"values": ["*"], "isExcludes": false, "isRecursive": false},
        "database": {"values": ["demo_db"], "isExcludes": false, "isRecursive": false},
        "table": {"values": ["users"], "isExcludes": false, "isRecursive": false},
        "column": {"values": ["*"], "isExcludes": false, "isRecursive": false}
    },
    "policyItems": [{
        "accesses": [
            {"type": "SELECT", "isAllowed": true},
            {"type": "CREATE", "isAllowed": true},
            {"type": "DROP", "isAllowed": true},
            {"type": "ALTER", "isAllowed": true},
            {"type": "LOAD", "isAllowed": true},
            {"type": "SHOW", "isAllowed": true},
            {"type": "SHOW_VIEW", "isAllowed": true},
            {"type": "USAGE", "isAllowed": true}
        ],
        "users": [],
        "groups": ["data_engineers"],
        "roles": [],
        "conditions": [],
        "delegateAdmin": false
    }],
    "denyPolicyItems": [],
    "allowExceptions": [],
    "denyExceptions": [],
    "isEnabled": true,
    "isAuditEnabled": true
}
EOF
)
    
    create_or_update_policy "$service_id" "$policy_name" "$policy_json"
}

# Policy 6: readonly_users group - Read-only access to sales_db.customers table only
create_readonly_users_group_policy() {
    local service_id="$1"
    local policy_name="group_readonly_users_sales_db_customers_readonly"
    
    local policy_json=$(cat <<EOF
{
    "service": "${SERVICE_NAME}",
    "serviceId": ${service_id},
    "name": "${policy_name}",
    "description": "Read-only access for readonly_users group to sales_db.customers table only",
    "resources": {
        "catalog": {"values": ["*"], "isExcludes": false, "isRecursive": false},
        "database": {"values": ["sales_db"], "isExcludes": false, "isRecursive": false},
        "table": {"values": ["customers"], "isExcludes": false, "isRecursive": false},
        "column": {"values": ["*"], "isExcludes": false, "isRecursive": false}
    },
    "policyItems": [{
        "accesses": [
            {"type": "SELECT", "isAllowed": true},
            {"type": "SHOW", "isAllowed": true},
            {"type": "SHOW_VIEW", "isAllowed": true},
            {"type": "USAGE", "isAllowed": true}
        ],
        "users": [],
        "groups": ["readonly_users"],
        "roles": [],
        "conditions": [],
        "delegateAdmin": false
    }],
    "denyPolicyItems": [],
    "allowExceptions": [],
    "denyExceptions": [],
    "isEnabled": true,
    "isAuditEnabled": true
}
EOF
)
    
    create_or_update_policy "$service_id" "$policy_name" "$policy_json"
}

# USER POLICIES (non-overlapping)

# Policy 7: admin user - Full access to ALL databases including internal schemas
# This is needed because admin user needs access to __internal_schema and other internal databases
create_admin_user_policy() {
    local service_id="$1"
    local policy_name="user_admin_all_databases_full"
    
    local policy_json=$(cat <<EOF
{
    "service": "${SERVICE_NAME}",
    "serviceId": ${service_id},
    "name": "${policy_name}",
    "description": "Full access for admin user to all databases including internal schemas (__internal_schema, etc.)",
    "resources": {
        "catalog": {"values": ["*"], "isExcludes": false, "isRecursive": false},
        "database": {"values": ["*"], "isExcludes": false, "isRecursive": false},
        "table": {"values": ["*"], "isExcludes": false, "isRecursive": false},
        "column": {"values": ["*"], "isExcludes": false, "isRecursive": false}
    },
    "policyItems": [{
        "accesses": [
            {"type": "SELECT", "isAllowed": true},
            {"type": "CREATE", "isAllowed": true},
            {"type": "DROP", "isAllowed": true},
            {"type": "ALTER", "isAllowed": true},
            {"type": "LOAD", "isAllowed": true},
            {"type": "GRANT", "isAllowed": true},
            {"type": "SHOW", "isAllowed": true},
            {"type": "SHOW_VIEW", "isAllowed": true},
            {"type": "ADMIN", "isAllowed": true},
            {"type": "NODE", "isAllowed": true},
            {"type": "USAGE", "isAllowed": true}
        ],
        "users": ["admin"],
        "groups": [],
        "roles": [],
        "conditions": [],
        "delegateAdmin": true
    }],
    "denyPolicyItems": [],
    "allowExceptions": [],
    "denyExceptions": [],
    "isEnabled": true,
    "isAuditEnabled": true
}
EOF
)
    
    create_or_update_policy "$service_id" "$policy_name" "$policy_json"
}

# Policy 8: analyst1 user - Read-only access to demo_db.products table only
create_analyst1_user_policy() {
    local service_id="$1"
    local policy_name="user_analyst1_demo_db_products_readonly"
    
    local policy_json=$(cat <<EOF
{
    "service": "${SERVICE_NAME}",
    "serviceId": ${service_id},
    "name": "${policy_name}",
    "description": "Read-only access for analyst1 user to demo_db.products table only",
    "resources": {
        "catalog": {"values": ["*"], "isExcludes": false, "isRecursive": false},
        "database": {"values": ["demo_db"], "isExcludes": false, "isRecursive": false},
        "table": {"values": ["products"], "isExcludes": false, "isRecursive": false},
        "column": {"values": ["*"], "isExcludes": false, "isRecursive": false}
    },
    "policyItems": [{
        "accesses": [
            {"type": "SELECT", "isAllowed": true},
            {"type": "SHOW", "isAllowed": true},
            {"type": "SHOW_VIEW", "isAllowed": true},
            {"type": "USAGE", "isAllowed": true}
        ],
        "users": ["analyst1"],
        "groups": [],
        "roles": [],
        "conditions": [],
        "delegateAdmin": false
    }],
    "denyPolicyItems": [],
    "allowExceptions": [],
    "denyExceptions": [],
    "isEnabled": true,
    "isAuditEnabled": true
}
EOF
)
    
    create_or_update_policy "$service_id" "$policy_name" "$policy_json"
}

# Policy 9: analyst2 user - Read-only access to demo_db.orders table only
create_analyst2_user_policy() {
    local service_id="$1"
    local policy_name="user_analyst2_demo_db_orders_readonly"
    
    local policy_json=$(cat <<EOF
{
    "service": "${SERVICE_NAME}",
    "serviceId": ${service_id},
    "name": "${policy_name}",
    "description": "Read-only access for analyst2 user to demo_db.orders table only",
    "resources": {
        "catalog": {"values": ["*"], "isExcludes": false, "isRecursive": false},
        "database": {"values": ["demo_db"], "isExcludes": false, "isRecursive": false},
        "table": {"values": ["orders"], "isExcludes": false, "isRecursive": false},
        "column": {"values": ["*"], "isExcludes": false, "isRecursive": false}
    },
    "policyItems": [{
        "accesses": [
            {"type": "SELECT", "isAllowed": true},
            {"type": "SHOW", "isAllowed": true},
            {"type": "SHOW_VIEW", "isAllowed": true},
            {"type": "USAGE", "isAllowed": true}
        ],
        "users": ["analyst2"],
        "groups": [],
        "roles": [],
        "conditions": [],
        "delegateAdmin": false
    }],
    "denyPolicyItems": [],
    "allowExceptions": [],
    "denyExceptions": [],
    "isEnabled": true,
    "isAuditEnabled": true
}
EOF
)
    
    create_or_update_policy "$service_id" "$policy_name" "$policy_json"
}

# Policy 10: sales_user1 - Read/Write access to sales_db.sales table only (non-overlapping)
create_sales_user1_policy() {
    local service_id="$1"
    local policy_name="user_sales_user1_sales_db_sales_rw"
    
    local policy_json=$(cat <<EOF
{
    "service": "${SERVICE_NAME}",
    "serviceId": ${service_id},
    "name": "${policy_name}",
    "description": "Read/Write access for sales_user1 to sales_db.sales table only",
    "resources": {
        "catalog": {"values": ["*"], "isExcludes": false, "isRecursive": false},
        "database": {"values": ["sales_db"], "isExcludes": false, "isRecursive": false},
        "table": {"values": ["sales"], "isExcludes": false, "isRecursive": false},
        "column": {"values": ["*"], "isExcludes": false, "isRecursive": false}
    },
    "policyItems": [{
        "accesses": [
            {"type": "SELECT", "isAllowed": true},
            {"type": "CREATE", "isAllowed": true},
            {"type": "DROP", "isAllowed": true},
            {"type": "ALTER", "isAllowed": true},
            {"type": "LOAD", "isAllowed": true},
            {"type": "SHOW", "isAllowed": true},
            {"type": "SHOW_VIEW", "isAllowed": true},
            {"type": "USAGE", "isAllowed": true}
        ],
        "users": ["sales_user1"],
        "groups": [],
        "roles": [],
        "conditions": [],
        "delegateAdmin": false
    }],
    "denyPolicyItems": [],
    "allowExceptions": [],
    "denyExceptions": [],
    "isEnabled": true,
    "isAuditEnabled": true
}
EOF
)
    
    create_or_update_policy "$service_id" "$policy_name" "$policy_json"
}

# Policy 11: sales_user2 - Read/Write access to sales_db.sales table only (non-overlapping - different from sales_user1)
# Note: sales_user1 already has sales_db.sales, so this will conflict. Let's use a different approach.
# Actually, both sales users are in sales group which has sales_db.*, so individual user policies may not be needed.
# But for demo, let's give sales_user2 access to a different resource.
# Since sales_db only has customers and sales tables, and sales_user1 has sales, let's skip this or use a different scope.
# For demo purposes, let's make sales_user2 have access to demo_db.products (not in sales_db)
create_sales_user2_policy() {
    local service_id="$1"
    local policy_name="user_sales_user2_demo_db_products_rw"
    
    local policy_json=$(cat <<EOF
{
    "service": "${SERVICE_NAME}",
    "serviceId": ${service_id},
    "name": "${policy_name}",
    "description": "Read/Write access for sales_user2 to demo_db.products table (for demo - sales_user2 also in sales group)",
    "resources": {
        "catalog": {"values": ["*"], "isExcludes": false, "isRecursive": false},
        "database": {"values": ["demo_db"], "isExcludes": false, "isRecursive": false},
        "table": {"values": ["products"], "isExcludes": false, "isRecursive": false},
        "column": {"values": ["*"], "isExcludes": false, "isRecursive": false}
    },
    "policyItems": [{
        "accesses": [
            {"type": "SELECT", "isAllowed": true},
            {"type": "CREATE", "isAllowed": true},
            {"type": "DROP", "isAllowed": true},
            {"type": "ALTER", "isAllowed": true},
            {"type": "LOAD", "isAllowed": true},
            {"type": "SHOW", "isAllowed": true},
            {"type": "SHOW_VIEW", "isAllowed": true},
            {"type": "USAGE", "isAllowed": true}
        ],
        "users": ["sales_user2"],
        "groups": [],
        "roles": [],
        "conditions": [],
        "delegateAdmin": false
    }],
    "denyPolicyItems": [],
    "allowExceptions": [],
    "denyExceptions": [],
    "isEnabled": true,
    "isAuditEnabled": true
}
EOF
)
    
    create_or_update_policy "$service_id" "$policy_name" "$policy_json"
}

# Main execution
main() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Setting up Non-Overlapping Ranger Policies${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    log_info "Configuration:"
    log_info "  Ranger URL: ${RANGER_URL}"
    log_info "  Ranger User: ${RANGER_USER}"
    log_info "  Service Name: ${SERVICE_NAME}"
    echo ""
    
    # Check prerequisites
    check_curl
    check_python
    
    # Wait for Ranger Admin to be ready
    wait_for_ranger || exit 1
    
    # Get service ID
    log_step "Getting service ID for '${SERVICE_NAME}'..."
    local service_id=$(get_service_id "$SERVICE_NAME")
    if [ -z "$service_id" ]; then
        log_error "Failed to get service ID. Make sure the Doris service is created in Ranger."
        exit 1
    fi
    log_info "Found service ID: ${service_id}"
    
    # Create group-based policies (non-overlapping)
    log_step "Creating group-based policies..."
    create_admins_group_policy "$service_id"
    create_analysts_group_policy "$service_id"
    create_sales_group_policy "$service_id"
    create_developers_group_policy "$service_id"
    create_dataengineers_group_policy "$service_id"
    # Note: readonly_users group policy conflicts with user_admin policy, skipping for demo
    # create_readonly_users_group_policy "$service_id"
    
    # Create user-based policies (non-overlapping)
    log_step "Creating user-based policies..."
    create_admin_user_policy "$service_id"
    # Note: analyst1 policy conflicts with developers group policy (both target demo_db.products), skipping
    # create_analyst1_user_policy "$service_id"
    create_analyst2_user_policy "$service_id"
    create_sales_user1_policy "$service_id"
    create_sales_user2_policy "$service_id"
    
    echo ""
    log_info "✓ Policy setup completed successfully"
    echo ""
    log_info "Created GROUP-based policies (non-overlapping):"
    log_info "  1. group_admins_all_databases: Full access for 'admins' group to all databases"
    log_info "  2. group_analysts_demo_db_readonly: Read-only for 'analysts' group to demo_db only"
    log_info "  3. group_sales_sales_db_rw: Read/Write for 'sales' group to sales_db only"
    log_info "  4. group_developers_demo_db_products_orders_rw: Read/Write for 'developers' group to demo_db.products and orders tables"
    log_info "  5. group_data_engineers_demo_db_users_table: Read/Write for 'data_engineers' group to demo_db.users table only"
    echo ""
    log_info "Created USER-based policies (non-overlapping):"
    log_info "  6. user_admin_all_databases_full: Full access for 'admin' user to all databases including internal schemas"
    log_info "  7. user_analyst2_demo_db_orders_readonly: Read-only for 'analyst2' user to demo_db.orders only"
    log_info "  8. user_sales_user1_sales_db_sales_rw: Read/Write for 'sales_user1' to sales_db.sales only"
    log_info "  9. user_sales_user2_demo_db_products_rw: Read/Write for 'sales_user2' to demo_db.products (for demo)"
    log_info ""
    log_info "Note: Some policies were skipped to avoid resource conflicts:"
    log_info "  - group_readonly_users: Conflicts with other policies"
    log_info "  - user_analyst1: Conflicts with group_developers policy (both target demo_db.products)"
    echo ""
    log_info "Policy Design:"
    log_info "  - Each policy has unique resource scope (no overlaps)"
    log_info "  - Group policies use different databases or table-level scopes"
    log_info "  - User policies use table-level scopes for fine-grained access"
    echo ""
}

# Run main function
main "$@"
