#!/bin/bash
#
# Master Start Script for NBD Demo Stack
# 
# This script brings up the entire demo stack including:
# - OpenLDAP (Directory Service)
# - Kerberos KDC (Authentication)
# - PostgreSQL (Ranger Database)
# - HDFS (NameNode + DataNode)
# - Apache Ranger Admin (Authorization & Audit)
# - Apache Doris (FE + BE)
#
# Note: Uses PostgreSQL as Ranger's backend database
#
# Usage: ./start.sh [options]
#   --skip-prereqs    Skip prerequisite checks
#   --skip-verify     Skip final verification
#   --clean           Clean up existing containers and volumes before starting
#   --help            Show this help message

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
SKIP_PREREQS=false
SKIP_VERIFY=false
CLEAN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-prereqs)
            SKIP_PREREQS=true
            shift
            ;;
        --skip-verify)
            SKIP_VERIFY=true
            shift
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --skip-prereqs    Skip prerequisite checks"
            echo "  --skip-verify     Skip final verification"
            echo "  --clean           Clean up existing containers and volumes before starting"
            echo "  --help            Show this help message"
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
    echo -e "\n${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}\n"
}

log_substep() {
    echo -e "${BLUE}→${NC} $1"
}

# Error handling
error_exit() {
    log_error "$1"
    exit 1
}

# Check prerequisites
check_prerequisites() {
    log_step "STEP 1: Checking Prerequisites"
    
    log_substep "Checking Docker installation..."
    if ! command -v docker &> /dev/null; then
        error_exit "Docker is not installed. Please install Docker first."
    fi
    log_info "Docker found: $(docker --version)"
    
    log_substep "Checking Docker Compose installation..."
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        error_exit "Docker Compose is not installed. Please install Docker Compose first."
    fi
    if docker compose version &> /dev/null; then
        COMPOSE_CMD="docker compose"
        log_info "Docker Compose found: $(docker compose version)"
    else
        COMPOSE_CMD="docker-compose"
        log_info "Docker Compose found: $(docker-compose --version)"
    fi
    
    log_substep "Checking Docker daemon..."
    if ! docker info &> /dev/null; then
        error_exit "Docker daemon is not running. Please start Docker first."
    fi
    log_info "Docker daemon is running"
    
    log_substep "Checking docker-compose.yml..."
    if [ ! -f "$COMPOSE_FILE" ]; then
        error_exit "docker-compose.yml not found at $COMPOSE_FILE"
    fi
    log_info "docker-compose.yml found"
    
    log_substep "Checking required configuration files..."
    local missing_files=()
    
    # Check Ranger configuration files
    [ ! -f "${SCRIPT_DIR}/ranger/ranger-admin-site.xml" ] && missing_files+=("ranger/ranger-admin-site.xml")
    [ ! -f "${SCRIPT_DIR}/ranger/ranger-usersync-site.xml" ] && missing_files+=("ranger/ranger-usersync-site.xml")
    [ ! -f "${SCRIPT_DIR}/ranger/custom-ranger-entrypoint.sh" ] && missing_files+=("ranger/custom-ranger-entrypoint.sh")
    [ ! -f "${SCRIPT_DIR}/ranger/install.properties" ] && missing_files+=("ranger/install.properties")
    [ ! -f "${SCRIPT_DIR}/ranger/persistence.xml" ] && missing_files+=("ranger/persistence.xml")
    [ ! -f "${SCRIPT_DIR}/ranger/ranger-servicedef-doris.json" ] && missing_files+=("ranger/ranger-servicedef-doris.json")
    
    # Check Kerberos configuration
    [ ! -f "${SCRIPT_DIR}/kerberos/Dockerfile" ] && missing_files+=("kerberos/Dockerfile")
    [ ! -f "${SCRIPT_DIR}/kerberos/krb5.conf" ] && missing_files+=("kerberos/krb5.conf")
    [ ! -f "${SCRIPT_DIR}/kerberos/kdc.conf" ] && missing_files+=("kerberos/kdc.conf")
    
    # Check HDFS configuration
    [ ! -f "${SCRIPT_DIR}/hdfs/core-site.xml" ] && missing_files+=("hdfs/core-site.xml")
    [ ! -f "${SCRIPT_DIR}/hdfs/hdfs-site.xml" ] && missing_files+=("hdfs/hdfs-site.xml")
    
    # Check Doris configuration
    [ ! -f "${SCRIPT_DIR}/doris/fe.conf" ] && missing_files+=("doris/fe.conf")
    [ ! -f "${SCRIPT_DIR}/doris/be.conf" ] && missing_files+=("doris/be.conf")
    
    if [ ${#missing_files[@]} -gt 0 ]; then
        log_error "Missing required configuration files:"
        for file in "${missing_files[@]}"; do
            echo "  - $file"
        done
        error_exit "Please ensure all configuration files are present"
    fi
    log_info "All required configuration files found"
    
    log_substep "Checking PostgreSQL driver..."
    if [ ! -f "${SCRIPT_DIR}/data/ranger/postgres-driver/postgresql-42.5.6.jar" ]; then
        log_warn "PostgreSQL driver not found. This will be downloaded automatically during setup."
        log_warn "Expected location: ${SCRIPT_DIR}/data/ranger/postgres-driver/postgresql-42.5.6.jar"
    else
        log_info "PostgreSQL driver found"
    fi
    
    log_substep "Checking Ranger Doris plugin..."
    local PLUGIN_DIR="${SCRIPT_DIR}/data/ranger/plugins/doris"
    local PLUGIN_JAR="${PLUGIN_DIR}/ranger-doris-plugin-3.0.0-SNAPSHOT.jar"
    
    if [ ! -f "$PLUGIN_JAR" ]; then
        log_warn "Ranger Doris plugin JAR not found: $PLUGIN_JAR"
        log_warn "This will be downloaded automatically during setup"
    else
        log_info "Ranger Doris plugin JAR found"
    fi
    
    log_info "Prerequisites check completed successfully"
}

# Create necessary directories
create_directories() {
    log_step "STEP 2: Creating Required Directories"
    
    local dirs=(
        "data/ldap/data"
        "data/ldap/config"
        "data/kerberos/krb5kdc"
        "data/kerberos/keytabs"
        "data/ranger/postgres"
        "data/ranger/postgres-driver"
        "data/ranger/conf"
        "data/ranger/plugins/doris"
        "data/ranger/META-INF"
        "data/hdfs/namenode"
        "data/hdfs/datanode"
        "data/doris/fe/doris-meta"
        "data/doris/fe/log"
        "data/doris/fe/conf"
        "data/doris/be/storage"
        "data/doris/be/log"
        "data/doris/be/conf"
    )
    
    for dir in "${dirs[@]}"; do
        local full_path="${SCRIPT_DIR}/${dir}"
        if [ ! -d "$full_path" ]; then
            mkdir -p "$full_path"
            log_substep "Created directory: $dir"
        else
            log_substep "Directory exists: $dir"
        fi
    done
    
    # Special handling for OpenLDAP directories
    # According to osixia/openldap documentation:
    # - Empty directories will trigger bootstrap (new LDAP server)
    # - Existing directories will be used as-is
    # - Corrupted/incomplete directories can cause startup failures
    # The container uses --copy-service flag to fix permission issues
    log_substep "Checking OpenLDAP initialization..."
    local ldap_data_dir="${SCRIPT_DIR}/data/ldap/data"
    local ldap_config_dir="${SCRIPT_DIR}/data/ldap/config"
    
    # Check if OpenLDAP is properly initialized
    # A properly initialized OpenLDAP should have:
    # - data/ldap/data: Contains database files (data.mdb for mdb backend)
    # - data/ldap/config: Contains slapd.d configuration (cn=config directory)
    local ldap_initialized=false
    
    if [ -d "$ldap_data_dir" ] && [ "$(ls -A "$ldap_data_dir" 2>/dev/null)" ] && \
       [ -d "$ldap_config_dir" ] && [ "$(ls -A "$ldap_config_dir" 2>/dev/null)" ]; then
        # Both directories exist and are not empty
        if [ -f "$ldap_data_dir/data.mdb" ] && [ -d "$ldap_config_dir/cn=config" ]; then
            ldap_initialized=true
            log_info "OpenLDAP appears to be initialized (found data.mdb and cn=config)"
        else
            log_warn "OpenLDAP directories exist but appear incomplete or corrupted"
            log_warn "Missing required files:"
            [ ! -f "$ldap_data_dir/data.mdb" ] && log_warn "  - $ldap_data_dir/data.mdb"
            [ ! -d "$ldap_config_dir/cn=config" ] && log_warn "  - $ldap_config_dir/cn=config"
            log_warn "Container will attempt to bootstrap, but if it fails, clean the directories:"
            log_warn "  rm -rf ${ldap_data_dir}/* ${ldap_config_dir}/*"
        fi
    else
        log_info "OpenLDAP directories are empty - container will bootstrap a new LDAP server"
    fi
    
    log_info "Directory structure ready"
}

# Download file if it doesn't exist
download_file() {
    local url=$1
    local dest=$2
    local description=$3
    
    if [ -f "$dest" ]; then
        log_info "$description already exists: $(basename $dest)"
        return 0
    fi
    
    log_substep "Downloading $description..."
    mkdir -p "$(dirname "$dest")"
    
    if command -v curl &> /dev/null; then
        if curl -L -f -o "$dest" "$url" 2>/dev/null; then
            log_info "Successfully downloaded: $(basename $dest)"
            return 0
        fi
    elif command -v wget &> /dev/null; then
        if wget -q -O "$dest" "$url" 2>/dev/null; then
            log_info "Successfully downloaded: $(basename $dest)"
            return 0
        fi
    else
        log_warn "Neither curl nor wget found. Cannot download $description"
        log_warn "Please download manually from: $url"
        log_warn "Save to: $dest"
        return 1
    fi
    
    log_warn "Failed to download $description from $url"
    return 1
}

# Setup PostgreSQL JDBC driver
setup_postgresql_driver() {
    log_substep "Setting up PostgreSQL JDBC driver..."
    
    local DRIVER_DIR="${SCRIPT_DIR}/data/ranger/postgres-driver"
    mkdir -p "$DRIVER_DIR"
    
    # Download PostgreSQL JDBC driver
    local DRIVER_JAR="${DRIVER_DIR}/postgresql-42.5.6.jar"
    local DRIVER_URL="https://jdbc.postgresql.org/download/postgresql-42.5.6.jar"
    
    if [ ! -f "$DRIVER_JAR" ]; then
        log_substep "Downloading PostgreSQL JDBC driver..."
        if download_file "$DRIVER_URL" "$DRIVER_JAR" "PostgreSQL JDBC driver"; then
            chmod 644 "$DRIVER_JAR"
        else
            log_error "PostgreSQL JDBC driver download failed. Ranger Admin will not start without it."
            log_warn "Please download manually from: $DRIVER_URL"
            log_warn "Save to: $DRIVER_JAR"
            return 1
        fi
    fi
    
    # Verify driver is present
    if [ -f "$DRIVER_JAR" ]; then
        log_info "PostgreSQL JDBC driver ready:"
        ls -lh "$DRIVER_JAR" 2>/dev/null | awk '{print "  - " $9 " (" $5 ")"}' || true
    else
        log_error "PostgreSQL JDBC driver is missing. Ranger Admin will fail to start."
        return 1
    fi
}

# Setup Ranger plugins
setup_ranger_plugins() {
    log_substep "Setting up Ranger plugins..."
    
    local PLUGIN_DIR="${SCRIPT_DIR}/data/ranger/plugins/doris"
    mkdir -p "$PLUGIN_DIR"
    
    # Download Ranger Doris plugin JAR
    local PLUGIN_JAR="${PLUGIN_DIR}/ranger-doris-plugin-3.0.0-SNAPSHOT.jar"
    local PLUGIN_URL="https://selectdb-doris-1308700295.cos.ap-beijing.myqcloud.com/ranger/ranger-doris-plugin-3.0.0-SNAPSHOT.jar"
    
    if [ ! -f "$PLUGIN_JAR" ]; then
        log_substep "Downloading Ranger Doris plugin..."
        if download_file "$PLUGIN_URL" "$PLUGIN_JAR" "Ranger Doris plugin"; then
            chmod 644 "$PLUGIN_JAR"
        else
            log_warn "Ranger Doris plugin download failed. You can download it manually:"
            log_warn "  URL: $PLUGIN_URL"
            log_warn "  Save to: $PLUGIN_JAR"
        fi
    fi
    
    # Verify plugin is present
    if [ -f "$PLUGIN_JAR" ]; then
        log_info "Ranger Doris plugin ready:"
        ls -lh "$PLUGIN_JAR" 2>/dev/null | awk '{print "  - " $9 " (" $5 ")"}' || true
    else
        log_warn "Ranger Doris plugin JAR is missing. Ranger-Doris integration may not work."
    fi
}

# Ensure configuration files are in place
setup_configuration() {
    log_step "STEP 3: Setting Up Configuration Files"
    
    log_substep "Copying Ranger configuration files..."
    if [ -f "${SCRIPT_DIR}/ranger/ranger-admin-site.xml" ]; then
        cp -f "${SCRIPT_DIR}/ranger/ranger-admin-site.xml" "${SCRIPT_DIR}/data/ranger/conf/ranger-admin-site.xml" 2>/dev/null || true
        log_info "Ranger Admin configuration copied"
    fi
    
    if [ -f "${SCRIPT_DIR}/ranger/ranger-usersync-site.xml" ]; then
        cp -f "${SCRIPT_DIR}/ranger/ranger-usersync-site.xml" "${SCRIPT_DIR}/data/ranger/conf/ranger-usersync-site.xml" 2>/dev/null || true
        log_info "Ranger Usersync configuration copied"
    fi
    
    log_substep "Copying persistence.xml..."
    if [ -f "${SCRIPT_DIR}/ranger/persistence.xml" ]; then
        mkdir -p "${SCRIPT_DIR}/data/ranger/META-INF"
        cp -f "${SCRIPT_DIR}/ranger/persistence.xml" "${SCRIPT_DIR}/data/ranger/META-INF/persistence.xml" 2>/dev/null || true
        log_info "persistence.xml copied to data directory"
    else
        log_error "Source persistence.xml not found at ${SCRIPT_DIR}/ranger/persistence.xml"
        error_exit "Please ensure persistence.xml exists at ranger/persistence.xml"
    fi
    
    # Verify persistence.xml is in place
    if [ ! -f "${SCRIPT_DIR}/data/ranger/META-INF/persistence.xml" ]; then
        log_error "Failed to copy persistence.xml. Ranger Admin requires this file."
        error_exit "Please ensure persistence.xml can be copied to data/ranger/META-INF/persistence.xml"
    fi
    log_info "persistence.xml verified"
    
    # Setup PostgreSQL JDBC driver (required for Ranger Admin)
    if ! setup_postgresql_driver; then
        error_exit "Failed to setup PostgreSQL JDBC driver. Ranger Admin cannot start without it."
    fi
    
    # Setup Ranger plugins
    setup_ranger_plugins
    
    log_substep "Copying Doris configuration files..."
    
    # Ensure Doris FE conf directory exists
    mkdir -p "${SCRIPT_DIR}/data/doris/fe/conf"
    
    # Copy Doris FE configuration files
    if [ -f "${SCRIPT_DIR}/doris/fe.conf" ]; then
        cp -f "${SCRIPT_DIR}/doris/fe.conf" "${SCRIPT_DIR}/data/doris/fe/conf/fe.conf" 2>/dev/null || true
        log_info "Doris FE fe.conf copied"
    fi
    
    if [ -f "${SCRIPT_DIR}/doris/ldap.conf" ]; then
        cp -f "${SCRIPT_DIR}/doris/ldap.conf" "${SCRIPT_DIR}/data/doris/fe/conf/ldap.conf" 2>/dev/null || true
        log_info "Doris FE ldap.conf copied"
    fi
    
    if [ -f "${SCRIPT_DIR}/doris/log4j.properties" ]; then
        cp -f "${SCRIPT_DIR}/doris/log4j.properties" "${SCRIPT_DIR}/data/doris/fe/conf/log4j.properties" 2>/dev/null || true
        log_info "Doris FE log4j.properties copied"
    fi
    
    if [ -f "${SCRIPT_DIR}/doris/ranger-doris-security.xml" ]; then
        cp -f "${SCRIPT_DIR}/doris/ranger-doris-security.xml" "${SCRIPT_DIR}/data/doris/fe/conf/ranger-doris-security.xml" 2>/dev/null || true
        log_info "Doris FE ranger-doris-security.xml copied"
    fi
    
    if [ -f "${SCRIPT_DIR}/doris/ranger-doris-audit.xml" ]; then
        cp -f "${SCRIPT_DIR}/doris/ranger-doris-audit.xml" "${SCRIPT_DIR}/data/doris/fe/conf/ranger-doris-audit.xml" 2>/dev/null || true
        log_info "Doris FE ranger-doris-audit.xml copied"
    fi
    
    # Copy HDFS configuration files (used by both FE and BE)
    if [ -f "${SCRIPT_DIR}/doris/core-site.xml" ]; then
        cp -f "${SCRIPT_DIR}/doris/core-site.xml" "${SCRIPT_DIR}/data/doris/fe/conf/core-site.xml" 2>/dev/null || true
        log_info "Doris FE core-site.xml copied"
    fi
    
    if [ -f "${SCRIPT_DIR}/doris/hdfs-site.xml" ]; then
        cp -f "${SCRIPT_DIR}/doris/hdfs-site.xml" "${SCRIPT_DIR}/data/doris/fe/conf/hdfs-site.xml" 2>/dev/null || true
        log_info "Doris FE hdfs-site.xml copied"
    fi
    
    # Ensure Doris BE conf directory exists
    mkdir -p "${SCRIPT_DIR}/data/doris/be/conf"
    
    # Copy Doris BE configuration files
    if [ -f "${SCRIPT_DIR}/doris/be.conf" ]; then
        cp -f "${SCRIPT_DIR}/doris/be.conf" "${SCRIPT_DIR}/data/doris/be/conf/be.conf" 2>/dev/null || true
        log_info "Doris BE be.conf copied"
    fi
    
    # Copy HDFS configuration files for BE
    if [ -f "${SCRIPT_DIR}/doris/core-site.xml" ]; then
        cp -f "${SCRIPT_DIR}/doris/core-site.xml" "${SCRIPT_DIR}/data/doris/be/conf/core-site.xml" 2>/dev/null || true
        log_info "Doris BE core-site.xml copied"
    fi
    
    if [ -f "${SCRIPT_DIR}/doris/hdfs-site.xml" ]; then
        cp -f "${SCRIPT_DIR}/doris/hdfs-site.xml" "${SCRIPT_DIR}/data/doris/be/conf/hdfs-site.xml" 2>/dev/null || true
        log_info "Doris BE hdfs-site.xml copied"
    fi
    
    # Copy SSL client configuration for BE
    if [ -f "${SCRIPT_DIR}/doris/ssl-client.xml" ]; then
        cp -f "${SCRIPT_DIR}/doris/ssl-client.xml" "${SCRIPT_DIR}/data/doris/be/conf/ssl-client.xml" 2>/dev/null || true
        log_info "Doris BE ssl-client.xml copied"
    fi
    
    log_info "Configuration setup completed"
}

# Clean up existing containers and volumes
cleanup() {
    if [ "$CLEAN" = true ]; then
        log_step "STEP 0: Cleaning Up Existing Containers and Volumes"
        
        log_substep "Stopping existing containers..."
        $COMPOSE_CMD -f "$COMPOSE_FILE" down -v 2>/dev/null || true
        
        log_substep "Removing orphaned containers..."
        docker container prune -f > /dev/null 2>&1 || true
        
        log_info "Cleanup completed"
    fi
}

# Wait for service to be healthy
wait_for_service() {
    local service=$1
    local max_attempts=${2:-60}
    local attempt=0
    
    log_substep "Waiting for $service to be healthy..."
    
    while [ $attempt -lt $max_attempts ]; do
        if docker inspect --format='{{.State.Health.Status}}' "nbd-${service}" 2>/dev/null | grep -q "healthy"; then
            log_info "$service is healthy"
            return 0
        fi
        
        # Check if container is running
        if ! docker ps --format '{{.Names}}' | grep -q "nbd-${service}"; then
            log_error "$service container is not running"
            docker logs "nbd-${service}" --tail 50 2>&1 || true
            return 1
        fi
        
        attempt=$((attempt + 1))
        if [ $((attempt % 10)) -eq 0 ]; then
            log_substep "Still waiting for $service... (attempt $attempt/$max_attempts)"
        fi
        sleep 2
    done
    
    log_error "$service did not become healthy within timeout"
    docker logs "nbd-${service}" --tail 50 2>&1 || true
    return 1
}

# Wait for service to be started (not necessarily healthy)
wait_for_service_started() {
    local service=$1
    local max_attempts=${2:-30}
    local attempt=0
    
    log_substep "Waiting for $service to start..."
    
    while [ $attempt -lt $max_attempts ]; do
        if docker ps --format '{{.Names}}' | grep -q "nbd-${service}"; then
            log_info "$service is running"
            return 0
        fi
        
        attempt=$((attempt + 1))
        sleep 2
    done
    
    log_error "$service did not start within timeout"
    return 1
}

# Setup Kerberos principals and keytabs
setup_kerberos() {
    log_step "STEP 4: Setting Up Kerberos Principals and Keytabs"
    
    local REALM="SISHUO.DEMO"
    local KEYTAB_DIR="${SCRIPT_DIR}/data/kerberos/keytabs"
    
    log_substep "Checking if keytabs already exist..."
    if [ -f "${KEYTAB_DIR}/hdfs-namenode.keytab" ] && \
       [ -f "${KEYTAB_DIR}/HTTP.keytab" ] && \
       [ -f "${KEYTAB_DIR}/doris-fe.keytab" ]; then
        log_info "Keytabs already exist, skipping creation"
        log_info "To regenerate keytabs, delete them and restart: rm -rf ${KEYTAB_DIR}/*.keytab"
        return 0
    fi
    
    log_substep "Waiting for Kerberos KDC to be ready..."
    local attempt=0
    while [ $attempt -lt 30 ]; do
        if docker exec nbd-kerberos kadmin.local -q 'list_principals' &> /dev/null; then
            break
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    
    if [ $attempt -eq 30 ]; then
        log_error "Kerberos KDC is not ready. Cannot create principals."
        return 1
    fi
    
    log_substep "Creating service principals..."
    
    # Create service principals using kadmin.local inside the container
    log_info "Creating HDFS principals..."
    docker exec nbd-kerberos kadmin.local -q "addprinc -randkey hdfs/namenode.nbd.demo@${REALM}" 2>&1 | grep -v "already exists" || true
    docker exec nbd-kerberos kadmin.local -q "addprinc -randkey dn/nbd-hdfs-datanode.nbdnet@${REALM}" 2>&1 | grep -v "already exists" || true
    
    log_info "Creating Ranger principal..."
    docker exec nbd-kerberos kadmin.local -q "addprinc -randkey HTTP/ranger.nbd.demo@${REALM}" 2>&1 | grep -v "already exists" || true
    
    log_info "Creating Doris principals..."
    docker exec nbd-kerberos kadmin.local -q "addprinc -randkey doris/fe1.nbd.demo@${REALM}" 2>&1 | grep -v "already exists" || true
    docker exec nbd-kerberos kadmin.local -q "addprinc -randkey doris/be1.nbd.demo@${REALM}" 2>&1 | grep -v "already exists" || true
    
    log_substep "Creating user principals..."
    docker exec nbd-kerberos kadmin.local -q "addprinc -pw password123 analyst1@${REALM}" 2>&1 | grep -v "already exists" || true
    docker exec nbd-kerberos kadmin.local -q "addprinc -pw password123 analyst2@${REALM}" 2>&1 | grep -v "already exists" || true
    docker exec nbd-kerberos kadmin.local -q "addprinc -pw password123 dataengineer1@${REALM}" 2>&1 | grep -v "already exists" || true
    
    log_substep "Generating keytab files..."
    
    # The keytab directory is mounted at /etc/security/keytabs in the container
    # Generate keytabs directly in the mounted directory
    log_info "Generating keytabs in mounted directory (/etc/security/keytabs)..."
    docker exec nbd-kerberos bash -c "
        kadmin.local -q 'ktadd -k /etc/security/keytabs/hdfs-namenode.keytab hdfs/namenode.nbd.demo@${REALM}' 2>&1 | grep -v 'already exists' || true
        kadmin.local -q 'ktadd -k /etc/security/keytabs/hdfs-datanode1.keytab dn/nbd-hdfs-datanode.nbdnet@${REALM}' 2>&1 | grep -v 'already exists' || true
        kadmin.local -q 'ktadd -k /etc/security/keytabs/HTTP.keytab HTTP/ranger.nbd.demo@${REALM}' 2>&1 | grep -v 'already exists' || true
        kadmin.local -q 'ktadd -k /etc/security/keytabs/doris-fe.keytab doris/fe1.nbd.demo@${REALM}' 2>&1 | grep -v 'already exists' || true
        kadmin.local -q 'ktadd -k /etc/security/keytabs/doris-be.keytab doris/be1.nbd.demo@${REALM}' 2>&1 | grep -v 'already exists' || true
        chmod 600 /etc/security/keytabs/*.keytab 2>/dev/null || true
    " || {
        log_warn "Failed to generate keytabs in mounted directory, trying alternative method..."
        # Fallback: generate in temp and copy
        docker exec nbd-kerberos bash -c "
            mkdir -p /tmp/keytabs
            kadmin.local -q 'ktadd -k /tmp/keytabs/hdfs-namenode.keytab hdfs/namenode.nbd.demo@${REALM}' 2>&1 | grep -v 'already exists' || true
            kadmin.local -q 'ktadd -k /tmp/keytabs/hdfs-datanode1.keytab dn/nbd-hdfs-datanode.nbdnet@${REALM}' 2>&1 | grep -v 'already exists' || true
            kadmin.local -q 'ktadd -k /tmp/keytabs/HTTP.keytab HTTP/ranger.nbd.demo@${REALM}' 2>&1 | grep -v 'already exists' || true
            kadmin.local -q 'ktadd -k /tmp/keytabs/doris-fe.keytab doris/fe1.nbd.demo@${REALM}' 2>&1 | grep -v 'already exists' || true
            kadmin.local -q 'ktadd -k /tmp/keytabs/doris-be.keytab doris/be1.nbd.demo@${REALM}' 2>&1 | grep -v 'already exists' || true
            chmod 600 /tmp/keytabs/*.keytab 2>/dev/null || true
        "
        # Copy keytabs from container to host
        docker cp nbd-kerberos:/tmp/keytabs/. "${KEYTAB_DIR}/" 2>/dev/null || {
            log_warn "Failed to copy keytabs from container"
        }
    }
    
    # Set permissions on host
    chmod 600 "${KEYTAB_DIR}"/*.keytab 2>/dev/null || true
    
    # Verify keytabs were created
    local keytab_count=$(ls -1 "${KEYTAB_DIR}"/*.keytab 2>/dev/null | wc -l)
    if [ "$keytab_count" -gt 0 ]; then
        log_info "Successfully created $keytab_count keytab file(s)"
        log_info "Keytabs location: ${KEYTAB_DIR}"
        ls -lh "${KEYTAB_DIR}"/*.keytab 2>/dev/null | awk '{print "  - " $9 " (" $5 ")"}' || true
    else
        log_warn "No keytabs were created. You may need to create them manually."
        log_warn "Run: docker exec -it nbd-kerberos kadmin.local"
    fi
    
    log_info "Kerberos principals and keytabs setup completed"
}

# Start infrastructure services
start_infrastructure() {
    log_step "STEP 5: Starting Infrastructure Services"
    
    log_substep "Starting OpenLDAP..."
    $COMPOSE_CMD -f "$COMPOSE_FILE" up -d openldap
    if ! wait_for_service "openldap" 30; then
        error_exit "OpenLDAP failed to start"
    fi
    
    log_substep "Starting Kerberos KDC..."
    $COMPOSE_CMD -f "$COMPOSE_FILE" up -d kerberos
    if ! wait_for_service "kerberos" 30; then
        error_exit "Kerberos KDC failed to start"
    fi
    
    # Setup Kerberos principals and keytabs after KDC is ready
    setup_kerberos
    
    log_substep "Starting PostgreSQL (Ranger Database)..."
    $COMPOSE_CMD -f "$COMPOSE_FILE" up -d ranger-db
    if ! wait_for_service "ranger-db" 30; then
        error_exit "PostgreSQL failed to start"
    fi
    
    log_info "Infrastructure services started successfully"
}

# Start HDFS services
start_hdfs() {
    log_step "STEP 6: Starting HDFS Services"
    
    log_substep "Starting HDFS NameNode..."
    $COMPOSE_CMD -f "$COMPOSE_FILE" up -d hdfs-namenode
    if ! wait_for_service "hdfs-namenode" 60; then
        log_warn "HDFS NameNode health check failed, but continuing..."
    fi
    
    log_substep "Starting HDFS DataNode..."
    $COMPOSE_CMD -f "$COMPOSE_FILE" up -d hdfs-datanode
    if ! wait_for_service_started "hdfs-datanode" 30; then
        log_warn "HDFS DataNode may not be fully ready, but continuing..."
    fi
    
    log_info "HDFS services started"
}

# Start Ranger Admin
start_ranger() {
    log_step "STEP 7: Starting Apache Ranger Admin"
    
    log_substep "Starting Ranger Admin..."
    $COMPOSE_CMD -f "$COMPOSE_FILE" up -d ranger-admin
    
    log_substep "Waiting for Ranger Admin to initialize..."
    # Give Ranger Admin time to start up (it has a long startup period)
    sleep 10
    
    if ! wait_for_service "ranger-admin" 120; then
        log_warn "Ranger Admin health check failed, but container may still be starting..."
        log_warn "Check logs with: docker logs nbd-ranger-admin"
    fi
    
    log_info "Ranger Admin started"
    log_info "Ranger Admin UI: http://localhost:6080"
    log_info "Login: admin / Admin123"
    
    # Upload Doris service definition to Ranger
    setup_ranger_doris_service_definition
}

# Start Doris services
start_doris() {
    log_step "STEP 8: Starting Apache Doris Services"
    
    log_substep "Starting Doris Frontend..."
    $COMPOSE_CMD -f "$COMPOSE_FILE" up -d doris-fe
    if ! wait_for_service "doris-fe" 60; then
        log_warn "Doris FE health check failed, but continuing..."
    fi
    
    log_substep "Starting Doris Backend..."
    $COMPOSE_CMD -f "$COMPOSE_FILE" up -d doris-be
    if ! wait_for_service "doris-be" 60; then
        log_warn "Doris BE health check failed, but continuing..."
    fi
    
    log_info "Doris services started"
    log_info "Doris Web UI: http://localhost:8030"
    log_info "Doris MySQL Port: localhost:9030"
}

# Setup Ranger Doris Service Definition
setup_ranger_doris_service_definition() {
    log_substep "Setting up Ranger Doris service definition..."
    
    local RANGER_URL="http://localhost:6080"
    local RANGER_USER="admin"
    local RANGER_PASSWORD="Admin123"
    local SERVICE_DEF_FILE="${SCRIPT_DIR}/ranger/ranger-servicedef-doris.json"
    
    # Check if service definition file exists
    if [ ! -f "$SERVICE_DEF_FILE" ]; then
        log_warn "Ranger Doris service definition file not found: $SERVICE_DEF_FILE"
        log_warn "Skipping service definition upload"
        return 0
    fi
    
    # Wait for Ranger Admin API to be ready (max 60 seconds)
    log_info "Waiting for Ranger Admin API to be ready..."
    local max_retries=60
    local retry=0
    local api_ready=false
    
    while [ $retry -lt $max_retries ]; do
        if curl -s -f -u "${RANGER_USER}:${RANGER_PASSWORD}" \
            "${RANGER_URL}/service/plugins/definitions?page=0&pageSize=1" &> /dev/null; then
            api_ready=true
            break
        fi
        retry=$((retry + 1))
        if [ $((retry % 10)) -eq 0 ]; then
            log_info "  Still waiting for Ranger Admin API... (${retry}/${max_retries})"
        fi
        sleep 1
    done
    
    if [ "$api_ready" != "true" ]; then
        log_warn "Ranger Admin API not ready after ${max_retries} seconds"
        log_warn "Skipping service definition upload. You can upload it manually:"
        log_warn "  curl -u ${RANGER_USER}:${RANGER_PASSWORD} -X POST \\"
        log_warn "    -H 'Content-Type: application/json' \\"
        log_warn "    ${RANGER_URL}/service/plugins/definitions \\"
        log_warn "    -d @${SERVICE_DEF_FILE}"
        return 0
    fi
    
    log_info "Ranger Admin API is ready"
    
    # Check if Doris service definition already exists
    log_info "Checking if Doris service definition already exists..."
    local existing_def=$(curl -s -w "\n%{http_code}" -u "${RANGER_USER}:${RANGER_PASSWORD}" \
        "${RANGER_URL}/service/plugins/definitions/name/doris" 2>/dev/null)
    
    local def_http_code=$(echo "$existing_def" | tail -n 1)
    local def_response=$(echo "$existing_def" | sed '$d')
    
    local def_exists=false
    # Check if we got a valid response (200) and it contains the service definition
    if [ "$def_http_code" = "200" ] && echo "$def_response" | grep -q '"name":"doris"' 2>/dev/null; then
        log_info "✓ Doris service definition already exists in Ranger"
        def_exists=true
    else
        log_info "Doris service definition not found (HTTP ${def_http_code}), will upload..."
        def_exists=false
    fi
    
    # Upload service definition if it doesn't exist
    if [ "$def_exists" != "true" ]; then
        log_info "Uploading Doris service definition to Ranger..."
        local upload_response=$(curl -s -w "\n%{http_code}" -u "${RANGER_USER}:${RANGER_PASSWORD}" \
            -X POST \
            -H 'Content-Type: application/json' \
            "${RANGER_URL}/service/plugins/definitions" \
            -d @"${SERVICE_DEF_FILE}" 2>/dev/null)
        
        local http_code=$(echo "$upload_response" | tail -n 1)
        local response_body=$(echo "$upload_response" | sed '$d')
        
        if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
            log_info "✓ Doris service definition uploaded successfully"
        elif echo "$response_body" | grep -q "already exists" 2>/dev/null; then
            log_info "✓ Doris service definition already exists (detected during upload)"
        else
            log_warn "⚠ Failed to upload Doris service definition (HTTP ${http_code})"
            log_warn "  Response: ${response_body}"
            log_warn "  You can upload it manually:"
            log_warn "    curl -u ${RANGER_USER}:${RANGER_PASSWORD} -X POST \\"
            log_warn "      -H 'Content-Type: application/json' \\"
            log_warn "      ${RANGER_URL}/service/plugins/definitions \\"
            log_warn "      -d @${SERVICE_DEF_FILE}"
            # Continue anyway - service instance creation might still work
        fi
    fi
    
    # Always create the Doris service instance (required for policy engine initialization)
    # This is what actually shows up in the Ranger Admin UI as a service
    create_ranger_doris_service_instance
    
    # Create default policy for root user to allow all operations
    # This is needed because Ranger blocks all access by default when no policies exist
    create_ranger_doris_default_policy
}

# Create Ranger Doris Service Instance
create_ranger_doris_service_instance() {
    log_substep "Creating Ranger Doris service instance..."
    
    local RANGER_URL="http://localhost:6080"
    local RANGER_USER="admin"
    local RANGER_PASSWORD="Admin123"
    local SERVICE_NAME="doris_nbd"  # Must match ranger.plugin.doris.service.name in ranger-doris-security.xml
    
    # Check if service instance already exists
    log_info "Checking if Doris service instance '${SERVICE_NAME}' already exists..."
    local existing_service=$(curl -s -w "\n%{http_code}" -u "${RANGER_USER}:${RANGER_PASSWORD}" \
        "${RANGER_URL}/service/public/v2/api/service/name/${SERVICE_NAME}" 2>/dev/null)
    
    local service_http_code=$(echo "$existing_service" | tail -n 1)
    local service_response=$(echo "$existing_service" | sed '$d')
    
    # Check if we got a valid response (200) and it contains the service name
    if [ "$service_http_code" = "200" ] && echo "$service_response" | grep -q '"name":"'"${SERVICE_NAME}"'"' 2>/dev/null; then
        log_info "✓ Doris service instance '${SERVICE_NAME}' already exists in Ranger"
        log_info "  Policy engine should be initialized"
        return 0
    elif [ "$service_http_code" = "404" ] || echo "$service_response" | grep -qi "not found" 2>/dev/null; then
        log_info "Doris service instance '${SERVICE_NAME}' not found, will create it..."
    else
        log_warn "Unexpected response when checking for service instance (HTTP ${service_http_code})"
        log_warn "  Response: ${service_response}"
        log_info "Will attempt to create service instance anyway..."
    fi
    
    # Create service instance JSON
    # Note: tagService is optional - only include if tag-based policies are needed
    # For basic setup, we omit it to avoid requiring a separate tag service
    local service_json=$(cat <<EOF
{
    "name": "${SERVICE_NAME}",
    "type": "doris",
    "description": "Apache Doris service for NBD demo",
    "configs": {
        "username": "root",
        "password": "",
        "jdbc.driverClassName": "com.mysql.cj.jdbc.Driver",
        "jdbc.url": "jdbc:mysql://fe1.nbd.demo:9030"
    },
    "isEnabled": true
}
EOF
)
    
    # Create the service instance
    log_info "Creating Doris service instance '${SERVICE_NAME}'..."
    local create_response=$(curl -s -w "\n%{http_code}" -u "${RANGER_USER}:${RANGER_PASSWORD}" \
        -X POST \
        -H 'Content-Type: application/json' \
        "${RANGER_URL}/service/public/v2/api/service" \
        -d "${service_json}" 2>/dev/null)
    
    local http_code=$(echo "$create_response" | tail -n 1)
    local response_body=$(echo "$create_response" | sed '$d')
    
    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        log_info "✓ Doris service instance '${SERVICE_NAME}' created successfully"
        log_info "  Ranger policy engine should now initialize for Doris"
    elif echo "$response_body" | grep -q "already exists" 2>/dev/null || echo "$response_body" | grep -q "duplicate" 2>/dev/null; then
        log_info "✓ Doris service instance already exists (detected during creation)"
    else
        log_warn "⚠ Failed to create Doris service instance (HTTP ${http_code})"
        log_warn "  Response: ${response_body}"
        log_warn "  You can create it manually in Ranger Admin UI:"
        log_warn "    1. Go to: ${RANGER_URL}"
        log_warn "    2. Navigate to: Service Manager > Create Service"
        log_warn "    3. Select: Apache Doris"
        log_warn "    4. Service Name: ${SERVICE_NAME}"
        log_warn "    5. Configure connection details and save"
        log_warn ""
        log_warn "  Or use API:"
        log_warn "    curl -u ${RANGER_USER}:${RANGER_PASSWORD} -X POST \\"
        log_warn "      -H 'Content-Type: application/json' \\"
        log_warn "      ${RANGER_URL}/service/public/v2/api/service \\"
        log_warn "      -d '${service_json}'"
    fi
}

# Create Default Ranger Policy for Doris Root User
create_ranger_doris_default_policy() {
    log_substep "Creating default Ranger policy for Doris root user..."
    
    local RANGER_URL="http://localhost:6080"
    local RANGER_USER="admin"
    local RANGER_PASSWORD="Admin123"
    local SERVICE_NAME="doris_nbd"
    
    # First, get the service ID (policies need service ID, not just name)
    log_info "Getting service ID for '${SERVICE_NAME}'..."
    local service_info=$(curl -s -w "\n%{http_code}" -u "${RANGER_USER}:${RANGER_PASSWORD}" \
        "${RANGER_URL}/service/public/v2/api/service/name/${SERVICE_NAME}" 2>/dev/null)
    
    local service_http_code=$(echo "$service_info" | tail -n 1)
    local service_response=$(echo "$service_info" | sed '$d')
    
    if [ "$service_http_code" != "200" ]; then
        log_warn "⚠ Could not retrieve service information (HTTP ${service_http_code})"
        log_warn "  Cannot create default policy without service ID"
        log_warn "  Response: ${service_response}"
        return 1
    fi
    
    # Extract service ID from response
    local service_id=$(echo "$service_response" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)
    
    if [ -z "$service_id" ]; then
        log_warn "⚠ Could not extract service ID from response"
        log_warn "  Response: ${service_response}"
        return 1
    fi
    
    log_info "Found service ID: ${service_id}"
    
    # Check if a default policy already exists and verify it has all required permissions
    log_info "Checking existing policies for root user..."
    local existing_policies=$(curl -s -w "\n%{http_code}" -u "${RANGER_USER}:${RANGER_PASSWORD}" \
        "${RANGER_URL}/service/public/v2/api/service/${service_id}/policy" 2>/dev/null)
    
    local policies_http_code=$(echo "$existing_policies" | tail -n 1)
    local policies_response=$(echo "$existing_policies" | sed '$d')
    
    # Check if we have policies for root user with CREATE permission
    if [ "$policies_http_code" = "200" ]; then
        # Check if any policy grants CREATE to root user
        if echo "$policies_response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    policies = data.get('policies', [])
    has_create = False
    for p in policies:
        if 'root' in str(p.get('policyItems', [])):
            for item in p.get('policyItems', []):
                if 'root' in item.get('users', []):
                    accesses = item.get('accesses', [])
                    for acc in accesses:
                        if acc.get('type') == 'CREATE' and acc.get('isAllowed'):
                            has_create = True
                            break
                    if has_create:
                        break
        if has_create:
            break
    print('HAS_CREATE' if has_create else 'NO_CREATE')
except:
    print('NO_CREATE')
" 2>/dev/null | grep -q "HAS_CREATE"; then
            log_info "✓ Found existing policies with CREATE permission for root user"
            log_info "  Policies should allow root user to create resources"
            # Still create our comprehensive policy to ensure coverage
            log_info "  Will create/update comprehensive policy to ensure all permissions are covered"
        else
            log_warn "⚠ Existing policies found but may be missing CREATE permission for root user"
            log_warn "  Will create comprehensive policy with all permissions"
        fi
    fi
    
    # Create default policy JSON that allows root user all privileges on all resources
    local policy_json=$(cat <<EOF
{
    "service": "${SERVICE_NAME}",
    "serviceId": ${service_id},
    "name": "root_all_privileges",
    "description": "Default policy allowing root user all privileges on all Doris resources",
    "resources": {
        "catalog": {
            "values": ["*"],
            "isExcludes": false,
            "isRecursive": false
        },
        "database": {
            "values": ["*"],
            "isExcludes": false,
            "isRecursive": false
        },
        "table": {
            "values": ["*"],
            "isExcludes": false,
            "isRecursive": false
        },
        "column": {
            "values": ["*"],
            "isExcludes": false,
            "isRecursive": false
        }
    },
    "policyItems": [
        {
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
            "users": ["root"],
            "groups": [],
            "roles": [],
            "conditions": [],
            "delegateAdmin": true
        }
    ],
    "denyPolicyItems": [],
    "allowExceptions": [],
    "denyExceptions": [],
    "isEnabled": true,
    "isAuditEnabled": true
}
EOF
)
    
    # Create the policy
    log_info "Creating default policy for root user..."
    local policy_response=$(curl -s -w "\n%{http_code}" -u "${RANGER_USER}:${RANGER_PASSWORD}" \
        -X POST \
        -H 'Content-Type: application/json' \
        "${RANGER_URL}/service/public/v2/api/policy" \
        -d "${policy_json}" 2>/dev/null)
    
    local http_code=$(echo "$policy_response" | tail -n 1)
    local response_body=$(echo "$policy_response" | sed '$d')
    
    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        log_info "✓ Default policy for root user created successfully"
        log_info "  Root user now has all privileges on all Doris resources"
    elif echo "$response_body" | grep -q "already exists" 2>/dev/null || echo "$response_body" | grep -q "duplicate" 2>/dev/null; then
        log_info "✓ Default policy already exists (detected during creation)"
    else
        log_warn "⚠ Failed to create default policy (HTTP ${http_code})"
        log_warn "  Response: ${response_body}"
        log_warn "  You may need to create a policy manually in Ranger Admin UI:"
        log_warn "    1. Go to: ${RANGER_URL}"
        log_warn "    2. Navigate to: Service Manager > ${SERVICE_NAME} > Add New Policy"
        log_warn "    3. Policy Name: root_all_privileges"
        log_warn "    4. User: root"
        log_warn "    5. Resources: catalog=*, database=*, table=*, column=*"
        log_warn "    6. Permissions: Select all (SELECT, CREATE, DROP, ALTER, LOAD, GRANT, SHOW, ADMIN, etc.)"
    fi
}

# Setup Doris Schema (databases and tables)
setup_doris_schema() {
    log_step "STEP 9: Setting up Doris Databases and Tables"
    
    local SETUP_SCRIPT="${SCRIPT_DIR}/scripts/setup-doris-schema.sh"
    
    if [ ! -f "$SETUP_SCRIPT" ]; then
        log_warn "Doris schema setup script not found: $SETUP_SCRIPT"
        log_warn "Skipping database and table creation"
        return 0
    fi
    
    if [ ! -x "$SETUP_SCRIPT" ]; then
        log_warn "Doris schema setup script is not executable: $SETUP_SCRIPT"
        log_warn "Making it executable..."
        chmod +x "$SETUP_SCRIPT"
    fi
    
    log_substep "Running Doris schema setup script..."
    if "$SETUP_SCRIPT" --host 127.0.0.1 --port 9030 --user root --skip-existing; then
        log_info "✓ Doris schema setup completed successfully"
    else
        log_warn "⚠ Doris schema setup encountered errors (check logs above)"
        log_warn "You can run it manually: $SETUP_SCRIPT"
    fi
}

# Setup Ranger Policies for Different Users
setup_ranger_user_policies() {
    log_step "STEP 10: Setting up Ranger Policies for Doris Users"
    
    local     SETUP_SCRIPT="${SCRIPT_DIR}/scripts/setup-ranger-policies-redesigned.sh"
    
    if [ ! -f "$SETUP_SCRIPT" ]; then
        log_warn "Ranger policies setup script not found: $SETUP_SCRIPT"
        log_warn "Skipping Ranger policy creation"
        return 0
    fi
    
    if [ ! -x "$SETUP_SCRIPT" ]; then
        log_warn "Ranger policies setup script is not executable: $SETUP_SCRIPT"
        log_warn "Making it executable..."
        chmod +x "$SETUP_SCRIPT"
    fi
    
    log_substep "Running Ranger policies setup script..."
    if "$SETUP_SCRIPT" \
        --ranger-url "http://localhost:6080" \
        --ranger-user "admin" \
        --ranger-pass "Admin123" \
        --service-name "doris_nbd" \
        --skip-existing; then
        log_info "✓ Ranger policies setup completed successfully"
    else
        log_warn "⚠ Ranger policies setup encountered errors (check logs above)"
        log_warn "You can run it manually: $SETUP_SCRIPT"
    fi
}

# Verify services
verify_services() {
    log_step "STEP 11: Verifying Services"
    
    local failed=0
    
    log_substep "Checking OpenLDAP..."
    if docker exec nbd-openldap ldapwhoami -x -H ldap://localhost -D 'cn=admin,dc=sishuo,dc=demo' -w admin123 &> /dev/null; then
        log_info "✓ OpenLDAP is responding"
    else
        log_error "✗ OpenLDAP is not responding"
        failed=$((failed + 1))
    fi
    
    log_substep "Checking Kerberos KDC..."
    if docker exec nbd-kerberos kadmin.local -q 'list_principals' &> /dev/null; then
        log_info "✓ Kerberos KDC is responding"
    else
        log_error "✗ Kerberos KDC is not responding"
        failed=$((failed + 1))
    fi
    
    log_substep "Checking PostgreSQL..."
    if docker exec nbd-ranger-db pg_isready -U ranger -d ranger &> /dev/null; then
        log_info "✓ PostgreSQL is responding"
    else
        log_error "✗ PostgreSQL is not responding"
        failed=$((failed + 1))
    fi
    
    log_substep "Checking HDFS NameNode..."
    if timeout 2 bash -c '</dev/tcp/localhost/9000' &> /dev/null; then
        log_info "✓ HDFS NameNode is responding"
    else
        log_warn "⚠ HDFS NameNode may not be ready (this is OK if Kerberos is not fully configured)"
    fi
    
    log_substep "Checking Ranger Admin..."
    # Simple check: verify port 6080 is accessible (curl available on host)
    if curl -s -f http://localhost:6080/login.jsp &> /dev/null; then
        log_info "✓ Ranger Admin UI is accessible at http://localhost:6080"
    else
        log_error "✗ Ranger Admin UI is not accessible"
        failed=$((failed + 1))
    fi
    
    log_substep "Checking Doris Frontend..."
    if curl -s -f http://localhost:8030/api/bootstrap &> /dev/null; then
        log_info "✓ Doris Frontend is responding"
    else
        log_warn "⚠ Doris Frontend may not be ready yet"
    fi
    
    if [ $failed -eq 0 ]; then
        log_info "All critical services are operational"
        return 0
    else
        log_warn "$failed service(s) failed verification"
        return 1
    fi
}

# Print summary
print_summary() {
    log_step "STARTUP COMPLETE"
    
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Service Access Information${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Apache Ranger Admin:${NC}"
    echo "  URL:      http://localhost:6080"
    echo "  Username: admin"
    echo "  Password: Admin123"
    echo ""
    echo -e "${CYAN}Apache Doris:${NC}"
    echo "  Web UI:   http://localhost:8030"
    echo "  MySQL:    localhost:9030"
    echo "  User:     root (default, no password)"
    echo ""
    echo -e "${CYAN}HDFS NameNode:${NC}"
    echo "  Web UI:   http://localhost:9870"
    echo "  RPC:      localhost:9000"
    echo ""
    echo -e "${CYAN}OpenLDAP:${NC}"
    echo "  Host:     localhost:389"
    echo "  Base DN:  dc=sishuo,dc=demo"
    echo "  Admin:    cn=admin,dc=sishuo,dc=demo / admin123"
    echo ""
    echo -e "${CYAN}PostgreSQL (Ranger DB):${NC}"
    echo "  Host:     localhost:5432"
    echo "  Database: ranger"
    echo "  User:     ranger"
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Next Steps:${NC}"
    echo "  1. Access Ranger Admin UI and configure usersync (Settings > Users/Groups > UserSync)"
    echo "  2. Upload Doris service definition to Ranger:"
    echo "     curl -u admin:Admin123 -X POST \\"
    echo "       -H 'Content-Type: application/json' \\"
    echo "       http://localhost:6080/service/plugins/definitions \\"
    echo "       -d @ranger/ranger-servicedef-doris.json"
    echo "  3. Create Doris service in Ranger WebUI (Service Manager > Apache Doris)"
    echo "  4. Create Ranger policies for Doris"
    echo "  5. Test Kerberos authentication"
    echo ""
    echo -e "${YELLOW}Useful Commands:${NC}"
    echo "  View logs:        docker logs nbd-<service-name>"
    echo "  Stop services:    docker-compose down"
    echo "  Restart service:  docker-compose restart <service-name>"
    echo "  Check status:     docker-compose ps"
    echo ""
}

# Main execution
main() {
    echo ""
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                                                               ║"
    echo "║          NBD Demo Stack - Master Start Script                ║"
    echo "║                                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    
    # Change to script directory
    cd "$SCRIPT_DIR"
    
    # Run cleanup if requested
    cleanup
    
    # Check prerequisites
    if [ "$SKIP_PREREQS" = false ]; then
        check_prerequisites
    else
        log_warn "Skipping prerequisite checks"
    fi
    
    # Create directories
    create_directories
    
    # Setup configuration
    setup_configuration
    
    # Start services in order
    start_infrastructure
    start_hdfs
    start_ranger
    start_doris
    
    # Setup Doris schema and Ranger policies (after services are ready)
    setup_doris_schema
    setup_ranger_user_policies
    
    # Verify services
    if [ "$SKIP_VERIFY" = false ]; then
        verify_services || log_warn "Some services failed verification. Check logs for details."
    else
        log_warn "Skipping service verification"
    fi
    
    # Print summary
    print_summary
}

# Run main function
main "$@"
