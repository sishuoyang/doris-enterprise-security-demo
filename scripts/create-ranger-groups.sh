#!/bin/bash
#
# Create LDAP Groups in Ranger Admin
#
# This script manually creates groups in Ranger Admin that match the LDAP groups.
# This is a workaround when Ranger Usersync is not syncing groups automatically.
#
# Usage: ./create-ranger-groups.sh [options]
#   --ranger-url URL     Ranger Admin URL (default: http://localhost:6080)
#   --ranger-user USER   Ranger Admin user (default: admin)
#   --ranger-pass PASS   Ranger Admin password (default: Admin123)
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

# LDAP Groups to create (matching ldap/ldif/03-groups.ldif)
LDAP_GROUPS=("admins" "analysts" "sales" "developers" "data_engineers" "readonly_users")

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
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --ranger-url URL     Ranger Admin URL (default: http://localhost:6080)"
            echo "  --ranger-user USER   Ranger Admin user (default: admin)"
            echo "  --ranger-pass PASS   Ranger Admin password (default: Admin123)"
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

# Check if group exists
group_exists() {
    local group_name="$1"
    local groups_response=$(curl -s -w "\n%{http_code}" -u "${RANGER_USER}:${RANGER_PASSWORD}" \
        "${RANGER_URL}/service/xusers/groups" 2>/dev/null)
    
    local http_code=$(echo "$groups_response" | tail -n 1)
    local response_body=$(echo "$groups_response" | sed '$d')
    
    if [ "$http_code" != "200" ]; then
        return 1
    fi
    
    echo "$response_body" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    groups = data.get('vXGroups', [])
    for g in groups:
        if g.get('name') == '${group_name}':
            sys.exit(0)
    sys.exit(1)
except:
    sys.exit(1)
" 2>/dev/null
    
    return $?
}

# Create a group
create_group() {
    local group_name="$1"
    
    if group_exists "$group_name"; then
        log_info "Group '${group_name}' already exists in Ranger"
        return 0
    fi
    
    log_info "Creating group '${group_name}'..."
    
    # Create group JSON
    # Based on Ranger API documentation: https://ranger.apache.org/apidocs/index.html
    # groupSource: 1 = External (LDAP), 0 = Internal
    # groupType: 1 = User group, 0 = System group
    # isVisible: 1 = Visible, 0 = Hidden
    local group_json=$(cat <<EOF
{
    "name": "${group_name}",
    "description": "LDAP group: ${group_name}",
    "groupType": 1,
    "groupSource": 1,
    "isVisible": 1
}
EOF
)
    
    local response=$(curl -s -w "\n%{http_code}" -u "${RANGER_USER}:${RANGER_PASSWORD}" \
        -X POST \
        -H 'Content-Type: application/json' \
        "${RANGER_URL}/service/xusers/groups" \
        -d "${group_json}" 2>/dev/null)
    
    local http_code=$(echo "$response" | tail -n 1)
    local response_body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        log_info "✓ Group '${group_name}' created successfully"
        return 0
    elif echo "$response_body" | grep -qi "already exists" 2>/dev/null; then
        log_info "✓ Group '${group_name}' already exists"
        return 0
    else
        log_warn "⚠ Failed to create group '${group_name}' (HTTP ${http_code})"
        log_warn "  Response: ${response_body}"
        return 1
    fi
}

# Main execution
main() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Creating LDAP Groups in Ranger Admin${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    log_info "Configuration:"
    log_info "  Ranger URL: ${RANGER_URL}"
    log_info "  Ranger User: ${RANGER_USER}"
    echo ""
    
    # Check prerequisites
    check_curl
    check_python
    
    # Create groups
    local created=0
    local failed=0
    
    for group in "${LDAP_GROUPS[@]}"; do
        if create_group "$group"; then
            created=$((created + 1))
        else
            failed=$((failed + 1))
        fi
    done
    
    echo ""
    if [ $failed -eq 0 ]; then
        log_info "✓ Successfully created/verified ${created} groups"
    else
        log_warn "⚠ Created ${created} groups, ${failed} failed"
    fi
    
    echo ""
    log_info "Created groups:"
    for group in "${LDAP_GROUPS[@]}"; do
        log_info "  - ${group}"
    done
    echo ""
    log_info "Note: After creating groups, the group-based policies should now display groups in the UI."
    log_info "      You may need to refresh the Ranger Admin UI to see the changes."
    echo ""
}

# Run main function
main "$@"
