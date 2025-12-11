#!/bin/bash
#
# Setup script for Kerberos KDC
# Creates all service principals and generates keytab files
#
# Usage: ./setup-kerberos.sh [REALM] [KDC_HOST]
#
# Defaults:
#   REALM: SISHUO.DEMO
#   KDC_HOST: kerberos.nbd.demo

set -euo pipefail

REALM="${1:-SISHUO.DEMO}"
KDC_HOST="${2:-kerberos.nbd.demo}"
KEYTAB_DIR="${KEYTAB_DIR:-./data/kerberos/keytabs}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Create keytab directory
mkdir -p "${KEYTAB_DIR}"

# Check if kadmin is available
if ! command -v kadmin &> /dev/null; then
    log_error "kadmin command not found. Please install krb5-user package."
    log_info "On Ubuntu/Debian: sudo apt-get install krb5-user"
    log_info "On RHEL/CentOS: sudo yum install krb5-workstation"
    exit 1
fi

# Check if we can connect to KDC
log_info "Checking connection to KDC at ${KDC_HOST}..."
if ! kadmin -p admin/admin@"${REALM}" -w admin123 -q "list_principals" &> /dev/null; then
    log_warn "Cannot connect to KDC. Trying with kadmin.local..."
    USE_LOCAL=true
else
    USE_LOCAL=false
fi

# Function to create principal
create_principal() {
    local principal=$1
    local description=$2
    
    log_info "Creating principal: ${principal}"
    
    if [ "$USE_LOCAL" = true ]; then
        kadmin.local -q "addprinc -randkey ${principal}" 2>/dev/null || {
            log_warn "Principal ${principal} may already exist, skipping..."
        }
    else
        kadmin -p admin/admin@"${REALM}" -w admin123 -q "addprinc -randkey ${principal}" 2>/dev/null || {
            log_warn "Principal ${principal} may already exist, skipping..."
        }
    fi
}

# Function to generate keytab
generate_keytab() {
    local principal=$1
    local keytab_file=$2
    
    log_info "Generating keytab for ${principal} -> ${keytab_file}"
    
    if [ "$USE_LOCAL" = true ]; then
        kadmin.local -q "ktadd -k ${keytab_file} ${principal}" 2>/dev/null || {
            log_error "Failed to generate keytab for ${principal}"
            return 1
        }
    else
        kadmin -p admin/admin@"${REALM}" -w admin123 -q "ktadd -k ${keytab_file} ${principal}" 2>/dev/null || {
            log_error "Failed to generate keytab for ${principal}"
            return 1
        }
    fi
    
    # Set appropriate permissions
    chmod 600 "${keytab_file}"
    log_info "Keytab created: ${keytab_file}"
}

# Function to create user principal
create_user_principal() {
    local username=$1
    local principal="${username}@${REALM}"
    
    log_info "Creating user principal: ${principal}"
    
    if [ "$USE_LOCAL" = true ]; then
        kadmin.local -q "addprinc -pw password123 ${principal}" 2>/dev/null || {
            log_warn "User principal ${principal} may already exist, skipping..."
        }
    else
        kadmin -p admin/admin@"${REALM}" -w admin123 -q "addprinc -pw password123 ${principal}" 2>/dev/null || {
            log_warn "User principal ${principal} may already exist, skipping..."
        }
    fi
}

log_info "=========================================="
log_info "Kerberos KDC Setup Script"
log_info "Realm: ${REALM}"
log_info "KDC Host: ${KDC_HOST}"
log_info "Keytab Directory: ${KEYTAB_DIR}"
log_info "=========================================="

# Create admin/admin principal (required for kadmin)
log_info "Creating admin/admin principal..."
if [ "$USE_LOCAL" = true ]; then
    kadmin.local -q "addprinc -pw admin123 admin/admin@${REALM}" 2>/dev/null || {
        log_warn "admin/admin principal may already exist, skipping..."
    }
else
    # If kadmin doesn't work, we need to use kadmin.local
    log_warn "Cannot create admin/admin via kadmin. Please run inside container:"
    log_warn "  docker exec -it nbd-kerberos kadmin.local -q 'addprinc -pw admin123 admin/admin@${REALM}'"
fi

# Create user principals
log_info "Creating user principals..."
create_user_principal "admin"
create_user_principal "analyst1"
create_user_principal "analyst2"
create_user_principal "dataengineer1"

# Create service principals
log_info "Creating service principals..."

# Doris principals
create_principal "doris/fe1.nbd.demo@${REALM}" "Doris Frontend 1"
create_principal "doris/be1.nbd.demo@${REALM}" "Doris Backend 1"
create_principal "doris/hdfs-client.nbd.demo@${REALM}" "Doris HDFS Client"

# HDFS principals
create_principal "hdfs/namenode.nbd.demo@${REALM}" "HDFS NameNode"
create_principal "hdfs/datanode1.nbd.demo@${REALM}" "HDFS DataNode 1"

# Ranger principal
create_principal "HTTP/ranger.nbd.demo@${REALM}" "Ranger HTTP Service"

# Generate keytabs
log_info "Generating keytab files..."

# Doris keytabs
generate_keytab "doris/fe1.nbd.demo@${REALM}" "${KEYTAB_DIR}/doris-fe.keytab"
generate_keytab "doris/be1.nbd.demo@${REALM}" "${KEYTAB_DIR}/doris-be.keytab"
generate_keytab "doris/hdfs-client.nbd.demo@${REALM}" "${KEYTAB_DIR}/doris-hdfs-client.keytab"

# HDFS keytabs
generate_keytab "hdfs/namenode.nbd.demo@${REALM}" "${KEYTAB_DIR}/hdfs-namenode.keytab"
generate_keytab "hdfs/datanode1.nbd.demo@${REALM}" "${KEYTAB_DIR}/hdfs-datanode1.keytab"

# Combined HDFS keytab (for services that need both)
log_info "Creating combined HDFS keytab..."
if [ "$USE_LOCAL" = true ]; then
    kadmin.local -q "ktadd -k ${KEYTAB_DIR}/hdfs.keytab hdfs/namenode.nbd.demo@${REALM} hdfs/datanode1.nbd.demo@${REALM}" 2>/dev/null || true
else
    kadmin -p admin/admin@"${REALM}" -w admin123 -q "ktadd -k ${KEYTAB_DIR}/hdfs.keytab hdfs/namenode.nbd.demo@${REALM} hdfs/datanode1.nbd.demo@${REALM}" 2>/dev/null || true
fi
chmod 600 "${KEYTAB_DIR}/hdfs.keytab"

# Ranger HTTP keytab
generate_keytab "HTTP/ranger.nbd.demo@${REALM}" "${KEYTAB_DIR}/HTTP.keytab"

# List all principals
log_info "Listing all principals:"
if [ "$USE_LOCAL" = true ]; then
    kadmin.local -q "list_principals"
else
    kadmin -p admin/admin@"${REALM}" -w admin123 -q "list_principals"
fi

log_info "=========================================="
log_info "Setup complete!"
log_info "Keytabs are located in: ${KEYTAB_DIR}"
log_info "=========================================="
log_info ""
log_info "Generated keytabs:"
ls -lh "${KEYTAB_DIR}"/*.keytab 2>/dev/null || true
log_info ""
log_info "To test authentication, run:"
log_info "  kinit analyst1@${REALM}"
log_info "  (password: password123)"
log_info "  klist"

