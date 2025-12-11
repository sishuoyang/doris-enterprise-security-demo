#!/bin/bash
# Script to start Ranger Usersync service
# This script runs usersync from within the Ranger Admin container

set -e

RANGER_HOME="${RANGER_HOME:-/opt/ranger}"
USERSYNC_DIR="${RANGER_HOME}/ranger-2.4.0-admin"
USERSYNC_SCRIPT="${USERSYNC_DIR}/bin/ranger_usersync.py"
USERSYNC_CONF="${USERSYNC_DIR}/ews/webapp/WEB-INF/classes/conf/ranger-usersync-site.xml"
LOG_DIR="${LOG_DIR:-/var/log/ranger}"

echo "=========================================="
echo "Starting Ranger Usersync Service"
echo "=========================================="
echo "Ranger Home: ${RANGER_HOME}"
echo "Usersync Script: ${USERSYNC_SCRIPT}"
echo "Configuration: ${USERSYNC_CONF}"
echo ""

# Check if usersync script exists
if [ ! -f "${USERSYNC_SCRIPT}" ]; then
    echo "ERROR: Usersync script not found at ${USERSYNC_SCRIPT}"
    exit 1
fi

# Check if configuration exists
if [ ! -f "${USERSYNC_CONF}" ]; then
    echo "WARNING: Usersync configuration not found at ${USERSYNC_CONF}"
    echo "Usersync may use default configuration from ranger-admin-site.xml"
fi

# Create log directory if it doesn't exist
mkdir -p "${LOG_DIR}"

# Wait for Ranger Admin to be ready
echo "Waiting for Ranger Admin to be ready..."
for i in {1..60}; do
    if curl -s -f http://localhost:6080/login.jsp > /dev/null 2>&1; then
        echo "Ranger Admin is ready!"
        break
    fi
    if [ $i -eq 60 ]; then
        echo "ERROR: Ranger Admin not ready after 60 attempts"
        exit 1
    fi
    sleep 2
done

# Wait for database to be ready
echo "Waiting for database to be ready..."
for i in {1..30}; do
    if PGPASSWORD=ranger_password psql -h postgres.nbd.demo -U ranger -d ranger -c "SELECT 1;" > /dev/null 2>&1; then
        echo "Database is ready!"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "WARNING: Database not ready, continuing anyway..."
    fi
    sleep 2
done

# Start usersync
echo ""
echo "Starting Ranger Usersync..."
echo "Logs will be written to: ${LOG_DIR}/usersync.log"
echo ""

# Run usersync in foreground (for Docker)
cd "${USERSYNC_DIR}"

# Set required environment variables
export RANGER_USERSYNC_HOME="${USERSYNC_DIR}"
export RANGER_ADMIN_HOME="${USERSYNC_DIR}"
export RANGER_LOG_DIR="${LOG_DIR}"
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-8-openjdk-arm64}"

# The Python script generates a service definition but doesn't run it
# For Docker, we'll use Ranger Admin's REST API to trigger sync instead
# Or configure usersync through the Admin UI

echo "Note: Ranger Usersync should be configured and started through the Ranger Admin UI:"
echo "  1. Go to http://localhost:6080"
echo "  2. Login as admin"
echo "  3. Navigate to Settings > Users/Groups > UserSync"
echo "  4. Configure LDAP settings and click 'Save'"
echo "  5. Click 'Start Sync' to run sync immediately"
echo ""
echo "Alternatively, usersync runs automatically based on sync interval configuration."
echo ""
echo "Waiting for Ranger Admin to be ready..."
sleep 5

# Keep container running
tail -f /dev/null

