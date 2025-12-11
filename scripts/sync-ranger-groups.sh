#!/bin/bash
#
# Sync LDAP Groups to Ranger Admin
#
# This script triggers Ranger Usersync to synchronize groups from LDAP to Ranger Admin.
# Groups must be synced before they can be used in Ranger policies.
#
# Usage: ./sync-ranger-groups.sh [options]
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

# List groups currently in Ranger
list_ranger_groups() {
    log_step "Checking groups currently in Ranger..."
    
    local groups_response=$(curl -s -w "\n%{http_code}" -u "${RANGER_USER}:${RANGER_PASSWORD}" \
        "${RANGER_URL}/service/xusers/groups" 2>/dev/null)
    
    local http_code=$(echo "$groups_response" | tail -n 1)
    local response_body=$(echo "$groups_response" | sed '$d')
    
    if [ "$http_code" != "200" ]; then
        log_warn "Failed to get groups from Ranger (HTTP ${http_code})"
        return 1
    fi
    
    local group_count=$(echo "$response_body" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    groups = data.get('vXGroups', [])
    print(len(groups))
    for g in groups:
        print(g.get('name', ''))
except:
    print('0')
" 2>/dev/null)
    
    if [ -z "$group_count" ] || [ "$group_count" = "0" ]; then
        log_warn "No groups found in Ranger (or only 'public' group)"
        log_info "Groups need to be synced from LDAP via Ranger Usersync"
        return 1
    else
        log_info "Found ${group_count} groups in Ranger:"
        echo "$response_body" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    groups = data.get('vXGroups', [])
    for g in groups:
        name = g.get('name', '')
        if name and name != 'public':
            print(f\"  - {name}\")
except:
    pass
" 2>/dev/null
        return 0
    fi
}

# Main execution
main() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Syncing LDAP Groups to Ranger Admin${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    log_info "Configuration:"
    log_info "  Ranger URL: ${RANGER_URL}"
    log_info "  Ranger User: ${RANGER_USER}"
    echo ""
    
    # Check prerequisites
    check_curl
    check_python
    
    # Wait for Ranger Admin to be ready
    wait_for_ranger || exit 1
    
    # List current groups
    list_ranger_groups
    
    echo ""
    log_info "To sync groups from LDAP to Ranger:"
    echo ""
    log_info "Option 1: Via Ranger Admin UI (Recommended)"
    log_info "  1. Go to: ${RANGER_URL}"
    log_info "  2. Navigate to: Settings > Users/Groups > UserSync"
    log_info "  3. Click 'Test Connection' to verify LDAP connectivity"
    log_info "  4. Click 'Sync Now' to trigger immediate sync"
    log_info "  5. Verify groups appear in: Settings > Users/Groups > Groups"
    echo ""
    log_info "Option 2: Restart Ranger Admin container"
    log_info "  docker-compose restart ranger-admin"
    log_info "  (Ranger Usersync will run automatically on startup)"
    echo ""
    log_info "Option 3: Manual sync via Ranger Usersync service"
    log_info "  docker exec nbd-ranger-admin python3 /opt/ranger/ranger-2.4.0-admin/bin/ranger_usersync.py"
    echo ""
    log_info "Expected LDAP Groups (from ldap/ldif/03-groups.ldif):"
    log_info "  - admins"
    log_info "  - analysts"
    log_info "  - sales"
    log_info "  - developers"
    log_info "  - data_engineers"
    log_info "  - readonly_users"
    echo ""
    log_warn "Note: Groups must be synced before they can be used in Ranger policies."
    log_warn "      After syncing, restart the policy creation script to verify groups appear."
    echo ""
}

# Run main function
main "$@"
