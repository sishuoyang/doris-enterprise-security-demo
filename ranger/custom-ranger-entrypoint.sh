#!/bin/bash
# Custom entrypoint for Ranger Admin that properly waits for service to be ready

set -e

RANGER_HOME=${RANGER_HOME:-/opt/ranger}
RANGER_SCRIPTS=${RANGER_SCRIPTS:-/home/ranger/scripts}

# Ensure HOSTNAME is set (required by Ranger Admin startup)
if [ -z "$HOSTNAME" ]; then
    export HOSTNAME=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "ranger.nbd.demo")
fi
export HOSTNAME

if [ ! -e ${RANGER_HOME}/.setupDone ]
then
  SETUP_RANGER=true
else
  SETUP_RANGER=false
fi

if [ "${SETUP_RANGER}" == "true" ]
then
  echo "Running Ranger Admin setup..."
  
  # CRITICAL: Setup configuration files BEFORE running setup.sh
  # The setup script expects certain config files to exist
  RANGER_ADMIN_DIR="${RANGER_HOME}/ranger-2.4.0-admin"
  CONF_DIST_DIR="${RANGER_ADMIN_DIR}/ews/webapp/WEB-INF/classes/conf.dist"
  CONF_DIR="${RANGER_ADMIN_DIR}/ews/webapp/WEB-INF/classes/conf"
  
  echo "Preparing configuration files for setup..."
  # Create conf directory if it doesn't exist
  mkdir -p "$CONF_DIR"
  
  # Copy default config files from conf.dist to conf (setup.sh needs them)
  if [ -d "$CONF_DIST_DIR" ]; then
    echo "Copying default configuration files from conf.dist..."
    # Copy all files from conf.dist to conf
    for file in "$CONF_DIST_DIR"/*; do
      if [ -f "$file" ]; then
        filename=$(basename "$file")
        cp "$file" "$CONF_DIR/" 2>/dev/null || true
      fi
    done
    echo "Default configuration files copied"
  else
    echo "WARNING: conf.dist directory not found at $CONF_DIST_DIR"
  fi
  
  # Wait for PostgreSQL to be ready before running setup
  echo "Waiting for PostgreSQL database to be ready..."
  MAX_DB_RETRIES=30
  DB_RETRY_INTERVAL=2
  DB_READY=false
  
  # Try multiple methods to check database readiness
  for i in $(seq 1 $MAX_DB_RETRIES); do
    # Method 1: Try using psql if available
    if command -v psql > /dev/null 2>&1; then
      if PGPASSWORD="${db_password}" psql -h "${db_host}" -U "${db_user}" -d "${db_name}" -c "SELECT 1;" > /dev/null 2>&1; then
        echo "PostgreSQL is ready! (checked via psql)"
        DB_READY=true
        break
      fi
    # Method 2: Try using telnet/nc to check if port is open
    elif command -v nc > /dev/null 2>&1; then
      if nc -z "${db_host}" 5432 > /dev/null 2>&1; then
        echo "PostgreSQL port is open (attempting connection)..."
        # Give it a moment and try again with psql on next iteration
        sleep 1
      fi
    # Method 3: Try using Java/JDBC to test connection (Ranger has Java)
    elif [ -f "${RANGER_HOME}/ranger-2.4.0-admin/ews/webapp/WEB-INF/lib/postgresql-42.5.6.jar" ]; then
      # Port check via bash TCP redirection
      if timeout 2 bash -c "</dev/tcp/${db_host}/5432" 2>/dev/null; then
        echo "PostgreSQL port is open, assuming database is ready"
        DB_READY=true
        break
      fi
    fi
    echo "Attempt $i/$MAX_DB_RETRIES: Waiting for PostgreSQL at ${db_host}..."
    sleep $DB_RETRY_INTERVAL
  done
  
  if [ "$DB_READY" != "true" ]; then
    echo "WARNING: Could not definitively verify PostgreSQL readiness"
    echo "Proceeding with setup - setup.sh will handle connection errors"
    echo "If setup fails, check:"
    echo "  - PostgreSQL container is running: docker ps | grep ranger-db"
    echo "  - Database is accessible: docker exec nbd-ranger-db pg_isready"
    echo "  - Network connectivity: ping postgres.nbd.demo"
  fi
  
  # Ensure log directory exists
  mkdir -p ${RANGER_HOME}/admin/logs
  
  # Set LOGFILE - use a simple path without spaces or special characters
  # setup.sh uses $LOGFILE in redirects without quoting, so we need a simple path
  export LOGFILE="${RANGER_HOME}/admin/logs/setup.log"
  # Ensure the log file directory exists
  mkdir -p "$(dirname "$LOGFILE")"
  
  # CRITICAL: Patch dba_script.py to automatically use quiet mode when install.properties exists
  # The setup script may call dba_script.py without -q, causing EOFError in non-interactive environments
  echo "Patching dba_script.py to auto-enable quiet mode..."
  cd ${RANGER_HOME}/admin
  
  if [ -f "./dba_script.py" ] && [ -f "./install.properties" ]; then
    # Backup original
    cp ./dba_script.py ./dba_script.py.bak 2>/dev/null || true
    
    # Simple patch: Add code at the beginning of main() to auto-add -q flag
    # Look for the main() function definition and insert our patch right after it starts
    if command -v python3 > /dev/null 2>&1; then
      python3 << 'PYTHON_PATCH'
import sys
import os
import re

script_path = './dba_script.py'
if not os.path.exists(script_path):
    print("dba_script.py not found")
    sys.exit(1)

with open(script_path, 'r') as f:
    content = f.read()

# Check if already patched
if 'AUTO_PATCH_QUIET_MODE' in content:
    print("dba_script.py already patched")
    sys.exit(0)

# Find the main() function and add auto-quiet mode logic
# Insert right after "def main(argv):" and before any other code
patch_code = '''\t# AUTO_PATCH_QUIET_MODE: Auto-enable quiet mode if install.properties exists
\t# This prevents EOFError in non-interactive Docker environments
\tif os.path.exists(os.path.join(RANGER_ADMIN_CONF, 'install.properties')):
\t\tif '-q' not in argv:
\t\t\targv.insert(0, '-q')
'''

# Find the main function definition
pattern = r'(def main\(argv\):)\s*\n'
match = re.search(pattern, content)

if match:
    # Insert our patch right after "def main(argv):"
    insert_pos = match.end()
    new_content = content[:insert_pos] + '\n' + patch_code + content[insert_pos:]
    
    with open(script_path, 'w') as f:
        f.write(new_content)
    print("✓ dba_script.py patched to auto-enable quiet mode")
else:
    print("⚠ Could not find main() function in dba_script.py")
    print("  Setup may still fail if dba_script.py is called without -q flag")
PYTHON_PATCH
    else
      echo "WARNING: python3 not available, cannot patch dba_script.py"
      echo "  Setup may fail if dba_script.py is called without -q flag"
    fi
  else
    echo "WARNING: dba_script.py or install.properties not found"
  fi
  
  # Run setup script and capture exit code
  echo "Running Ranger Admin setup script..."
  # Use quoted LOGFILE to avoid ambiguous redirect errors
  # Redirect both stdout and stderr to log file, and also display on console
  if ./setup.sh 2>&1 | tee "${LOGFILE}"; then
    SETUP_EXIT_CODE=${PIPESTATUS[0]}
  else
    SETUP_EXIT_CODE=$?
  fi
  
  # Check if setup succeeded
  if [ "$SETUP_EXIT_CODE" -ne 0 ]; then
    echo "ERROR: Ranger Admin setup script failed with exit code $SETUP_EXIT_CODE"
    echo "Check the setup log at: ${LOGFILE}"
    echo "Last 50 lines of setup log:"
    tail -50 ${LOGFILE} 2>/dev/null || true
    exit 1
  fi
  
  # Verify database schema was created (if psql is available)
  if command -v psql > /dev/null 2>&1; then
    echo "Verifying database schema was created..."
    if PGPASSWORD="${db_password}" psql -h "${db_host}" -U "${db_user}" -d "${db_name}" -c "\dt x_auth_sess" > /dev/null 2>&1; then
      echo "✓ Database schema verification: x_auth_sess table exists"
      
      # Verify other critical tables exist
      CRITICAL_TABLES=("x_auth_sess" "x_portal_user" "x_policy" "x_service_def")
      ALL_TABLES_EXIST=true
      for table in "${CRITICAL_TABLES[@]}"; do
        if ! PGPASSWORD="${db_password}" psql -h "${db_host}" -U "${db_user}" -d "${db_name}" -c "\dt ${table}" > /dev/null 2>&1; then
          echo "WARNING: Critical table ${table} may not exist"
          ALL_TABLES_EXIST=false
        fi
      done
      
      if [ "$ALL_TABLES_EXIST" = true ]; then
        echo "✓ All critical database tables verified"
      else
        echo "WARNING: Some critical tables may be missing. Setup may have failed partially."
        echo "Check setup log: ${LOGFILE}"
      fi
    else
      echo "WARNING: Could not verify database schema - psql verification failed"
      echo "Setup log should be checked manually: ${LOGFILE}"
      echo "If you see 'relation does not exist' errors, the setup may have failed"
    fi
  else
    echo "Note: psql not available in container, skipping schema verification"
    echo "Check setup log at: ${LOGFILE} for any errors"
    echo "If Ranger Admin fails to start with 'relation does not exist' errors,"
    echo "the database schema was not created. Check the setup log for database connection issues."
  fi

  touch ${RANGER_HOME}/.setupDone
  echo "Ranger Admin setup completed"
else
  echo "Ranger Admin setup already completed (${RANGER_HOME}/.setupDone exists)"
fi

echo "Starting Ranger Admin service..."

# Ensure all required log directories exist BEFORE starting the service
RANGER_ADMIN_DIR="${RANGER_HOME}/ranger-2.4.0-admin"

# CRITICAL: Copy required configuration files from conf.dist to conf
# The webapp expects these files in conf/ but they're in conf.dist/
# NOTE: conf/ is mounted from host, so we need to be careful about writes
CONF_DIST_DIR="${RANGER_ADMIN_DIR}/ews/webapp/WEB-INF/classes/conf.dist"
CONF_DIR="${RANGER_ADMIN_DIR}/ews/webapp/WEB-INF/classes/conf"
TEMP_CONFIG_DIR="/tmp/ranger-config"

echo "Setting up configuration files..."

# Check if conf directory is a mount point (it should be from docker-compose)
if mountpoint -q "$CONF_DIR" 2>/dev/null; then
    echo "conf directory is a mount point (from host)"
    # Files should already be in place from host, but verify
    if [ ! -f "$CONF_DIR/ranger-admin-site.xml" ]; then
        echo "WARNING: ranger-admin-site.xml not found in mounted conf directory"
        echo "  Expected at: $CONF_DIR/ranger-admin-site.xml"
        echo "  This file should be copied by start.sh script to data/ranger/conf/"
    else
        echo "✓ ranger-admin-site.xml found in mounted conf directory"
        # Verify it has the PostgreSQL dialect property
        if grep -q "ranger.jpa.jdbc.dialect.*PostgreSQL" "$CONF_DIR/ranger-admin-site.xml"; then
            echo "✓ ranger-admin-site.xml has PostgreSQL dialect configured"
        else
            echo "WARNING: ranger-admin-site.xml does NOT have PostgreSQL dialect property!"
            echo "  This is the root cause of MySQL syntax errors"
        fi
    fi
    
    # Still copy missing files from conf.dist (if writable)
    if [ -w "$CONF_DIR" ] && [ -d "$CONF_DIST_DIR" ]; then
        echo "Copying missing default config files from conf.dist..."
        for file in "$CONF_DIST_DIR"/*; do
            if [ -f "$file" ]; then
                filename=$(basename "$file")
                # Only copy if file doesn't exist and it's not ranger-admin-site.xml
                if [ "$filename" != "ranger-admin-site.xml" ] && [ ! -f "$CONF_DIR/$filename" ]; then
                    cp "$file" "$CONF_DIR/" 2>/dev/null && echo "  Copied: $filename" || echo "  Failed to copy: $filename (may be read-only mount)"
                fi
            fi
        done
    fi
else
    # Not a mount point, create directory and copy files normally
    echo "conf directory is not a mount point, creating and copying files..."
mkdir -p "$CONF_DIR"

    # Copy all files from conf.dist, but preserve our custom ranger-admin-site.xml
if [ -d "$CONF_DIST_DIR" ]; then
    echo "Copying configuration files from conf.dist..."
    # Backup our custom ranger-admin-site.xml if it exists
    if [ -f "$CONF_DIR/ranger-admin-site.xml" ]; then
        cp "$CONF_DIR/ranger-admin-site.xml" "$CONF_DIR/ranger-admin-site.xml.backup" 2>/dev/null || true
    fi
    
    # Copy files from conf.dist, but skip ranger-admin-site.xml to preserve our custom one
    for file in "$CONF_DIST_DIR"/*; do
        if [ -f "$file" ]; then
            filename=$(basename "$file")
            if [ "$filename" != "ranger-admin-site.xml" ]; then
                cp "$file" "$CONF_DIR/" 2>/dev/null || true
            fi
        fi
    done
    
    # Restore our custom ranger-admin-site.xml
    if [ -f "$CONF_DIR/ranger-admin-site.xml.backup" ]; then
        mv "$CONF_DIR/ranger-admin-site.xml.backup" "$CONF_DIR/ranger-admin-site.xml" 2>/dev/null || true
    fi
    fi
fi

# Verify ranger-admin-site.xml is present and has correct configuration
if [ -f "$CONF_DIR/ranger-admin-site.xml" ]; then
    echo "Verifying ranger-admin-site.xml configuration..."
    if grep -q "ranger.jpa.jdbc.dialect.*PostgreSQL" "$CONF_DIR/ranger-admin-site.xml"; then
        echo "✓ ranger-admin-site.xml has PostgreSQL dialect: org.eclipse.persistence.platform.database.PostgreSQLPlatform"
    else
        echo "✗ CRITICAL: ranger-admin-site.xml missing PostgreSQL dialect property!"
        echo "  This will cause MySQL syntax errors. The property should be:"
        echo "  <property><name>ranger.jpa.jdbc.dialect</name><value>org.eclipse.persistence.platform.database.PostgreSQLPlatform</value></property>"
    fi
else
    echo "✗ CRITICAL: ranger-admin-site.xml not found at $CONF_DIR/ranger-admin-site.xml"
    echo "  This file must be present for Ranger Admin to work correctly"
fi

# Set ownership (may fail if mount is read-only, that's OK)
chown -R ranger:ranger "$CONF_DIR" 2>/dev/null || true
chmod -R 644 "$CONF_DIR"/*.xml 2>/dev/null || true
chmod -R 644 "$CONF_DIR"/*.properties 2>/dev/null || true

# CRITICAL: Copy persistence.xml with PostgreSQL dialect configuration
# EclipseLink defaults to MySQL dialect, which generates MySQL-style LIMIT syntax
# PostgreSQL requires LIMIT count OFFSET offset instead of LIMIT offset, count
META_INF_DIR="${RANGER_ADMIN_DIR}/ews/webapp/WEB-INF/classes/META-INF"
mkdir -p "$META_INF_DIR"

# Copy persistence.xml from mounted location (if mounted) or use default
PERSISTENCE_XML_SOURCE="/opt/ranger/ranger-2.4.0-admin/ews/webapp/WEB-INF/classes/META-INF/persistence.xml"
PERSISTENCE_XML_TARGET="$META_INF_DIR/persistence.xml"

# Check if source exists and is readable (might be read-only mount)
if [ -f "$PERSISTENCE_XML_SOURCE" ] && [ -r "$PERSISTENCE_XML_SOURCE" ]; then
    echo "Copying persistence.xml from mounted location..."
    # Try to copy - if it fails because source is read-only mount, we'll use a workaround
    cp "$PERSISTENCE_XML_SOURCE" "$PERSISTENCE_XML_TARGET" 2>/dev/null || {
        echo "WARNING: Could not copy persistence.xml directly, using cat to copy..."
        cat "$PERSISTENCE_XML_SOURCE" > "$PERSISTENCE_XML_TARGET" 2>/dev/null || {
            echo "WARNING: Could not copy persistence.xml, but it should be accessible at mount point"
        }
    }
else
    echo "WARNING: persistence.xml not found at $PERSISTENCE_XML_SOURCE"
fi

# Verify persistence.xml has PostgreSQL dialect configured
if [ -f "$PERSISTENCE_XML_TARGET" ]; then
    if ! grep -q "eclipselink.target-database.*PostgreSQL" "$PERSISTENCE_XML_TARGET"; then
        echo "WARNING: persistence.xml does not have PostgreSQL dialect configured!"
        echo "Note: persistence.xml is read-only (mounted), but should have PostgreSQL configured"
    else
        echo "✓ persistence.xml has PostgreSQL dialect configured"
    fi
fi

chown -R ranger:ranger "$META_INF_DIR" 2>/dev/null || true
chmod -R 644 "$META_INF_DIR"/*.xml 2>/dev/null || true

echo "Configuration files setup completed."
ls -la "$CONF_DIR" | head -10

# The script checks for RANGER_ADMIN_LOG_DIR, and if not set, uses ${XAPOLICYMGR_EWS_DIR}/logs
# We need to create the ews/logs directory which is the fallback path
RANGER_ADMIN_EWS_LOG_DIR="${RANGER_ADMIN_DIR}/ews/logs"
RANGER_ADMIN_LOG_DIR="${RANGER_ADMIN_LOG_DIR:-/var/log/ranger}"

# Create both log directories (script may use either depending on env vars)
mkdir -p ${RANGER_ADMIN_LOG_DIR}
mkdir -p ${RANGER_ADMIN_EWS_LOG_DIR}
mkdir -p /var/run/ranger

# Set ownership (may fail in some environments, that's OK)
chown -R ranger:ranger ${RANGER_ADMIN_LOG_DIR} ${RANGER_ADMIN_EWS_LOG_DIR} /var/run/ranger 2>/dev/null || true
chmod -R 755 ${RANGER_ADMIN_LOG_DIR} ${RANGER_ADMIN_EWS_LOG_DIR} /var/run/ranger 2>/dev/null || true

# Export environment variables that the startup script expects
# IMPORTANT: The script sources ranger-admin-env.sh which may override these
# So we need to ensure the directories exist regardless of which path is used
export RANGER_ADMIN_LOG_DIR="${RANGER_ADMIN_LOG_DIR}"
export RANGER_ADMIN_LOGBACK_CONF_FILE="${RANGER_ADMIN_DIR}/ews/webapp/WEB-INF/classes/conf/logback.xml"
export RANGER_PID_DIR_PATH="/var/run/ranger"

# Verify directories were created
if [ ! -d "${RANGER_ADMIN_EWS_LOG_DIR}" ]; then
    echo "ERROR: Failed to create log directory: ${RANGER_ADMIN_EWS_LOG_DIR}"
    exit 1
fi

echo "Log directories created: ${RANGER_ADMIN_LOG_DIR} and ${RANGER_ADMIN_EWS_LOG_DIR}"

# Change to the admin directory and start the service
# The script sources ranger-admin-env.sh which may override RANGER_ADMIN_LOG_DIR
# We need to ensure the directory exists in the script's fallback location too
XAPOLICYMGR_EWS_DIR="${RANGER_ADMIN_DIR}/ews"
mkdir -p ${XAPOLICYMGR_EWS_DIR}/logs
chown -R ranger:ranger ${XAPOLICYMGR_EWS_DIR}/logs 2>/dev/null || true
chmod -R 755 ${XAPOLICYMGR_EWS_DIR}/logs 2>/dev/null || true

echo "All log directories prepared. Starting Ranger Admin..."

# CRITICAL FIX: The startup script uses ${HOSTNAME} in the Java command
# If HOSTNAME is empty, it passes an empty string to Java, causing "Host name is required"
# We must ensure HOSTNAME is set and NOT empty when the script executes
# The script sources env files that may unset HOSTNAME, so we set it explicitly in the command line
export HOSTNAME="ranger.nbd.demo"
export USER="ranger"

echo "Using HOSTNAME: $HOSTNAME"
echo "Using USER: $USER"

# Start the service - ensure HOSTNAME is set in the environment when script runs
cd ${RANGER_HOME}/admin

# CRITICAL FIX: Ensure PostgreSQL dialect is set for EclipseLink
# EclipseLink must use PostgreSQL dialect to generate correct SQL syntax (LIMIT ? OFFSET ? instead of LIMIT ?, ?)
# We set this via Java system property which takes precedence over persistence.xml

# Set environment variable that will be picked up by the startup script
# Use the full class name - this is the most reliable way for EclipseLink 2.7.12
# CRITICAL: The startup script may source env files that reset JAVA_OPTS, so we also patch the script directly
DIALECT_PROP="-Declipselink.target-database=org.eclipse.persistence.platform.database.PostgreSQLPlatform"

# Ensure JAVA_OPTS includes the dialect (append if not already present)
if [ -z "$JAVA_OPTS" ] || ! echo "$JAVA_OPTS" | grep -q "eclipselink.target-database.*PostgreSQL"; then
    export JAVA_OPTS="${JAVA_OPTS} ${DIALECT_PROP}"
fi

# Also set RANGER_ADMIN_OPTS (some scripts use this instead)
if [ -z "$RANGER_ADMIN_OPTS" ] || ! echo "$RANGER_ADMIN_OPTS" | grep -q "eclipselink.target-database.*PostgreSQL"; then
    export RANGER_ADMIN_OPTS="${RANGER_ADMIN_OPTS} ${DIALECT_PROP}"
fi

echo "Setting PostgreSQL dialect for EclipseLink:"
echo "  JAVA_OPTS: ${JAVA_OPTS}"
echo "  RANGER_ADMIN_OPTS: ${RANGER_ADMIN_OPTS}"

# CRITICAL FIX: Patch the startup script to hardcode hostname
# The script uses ${HOSTNAME} which may be empty after sourcing env files
if grep -q -- "-Dhostname=\${HOSTNAME}" ./ews/ranger-admin-services.sh 2>/dev/null; then
    echo "Patching hostname in startup script..."
        sed -i.bak 's/-Dhostname=${HOSTNAME}/-Dhostname=ranger.nbd.demo/g' ./ews/ranger-admin-services.sh 2>/dev/null || true
    fi

# CRITICAL: Ensure PostgreSQL dialect property is in the startup script
# The startup script may source env files that override JAVA_OPTS, so we need to hardcode it
# Use the full class name for maximum compatibility
echo "Patching startup script to include PostgreSQL dialect in Java command..."

# Find where the Java command is constructed in the startup script
# Look for patterns like: java ... org.apache.ranger.server.tomcat.EmbeddedServer
if ! grep -q -- "eclipselink.target-database=org.eclipse.persistence.platform.database.PostgreSQLPlatform" ./ews/ranger-admin-services.sh 2>/dev/null; then
    echo "Adding PostgreSQL dialect property directly to startup script..."
    
    # Method 1: Try to add after hostname property (most reliable)
    if grep -q "-Dhostname=ranger\.nbd\.demo" ./ews/ranger-admin-services.sh 2>/dev/null; then
        sed -i.bak2 's/-Dhostname=ranger\.nbd\.demo\([[:space:]]\)/-Dhostname=ranger.nbd.demo -Declipselink.target-database=org.eclipse.persistence.platform.database.PostgreSQLPlatform\1/g' ./ews/ranger-admin-services.sh 2>/dev/null && \
        echo "  ✓ Added after hostname property" || echo "  ⚠ Failed to add after hostname"
    fi
    
    # Method 2: Try to add before the main class (org.apache.ranger.server.tomcat.EmbeddedServer)
    if ! grep -q "eclipselink.target-database=org.eclipse.persistence.platform.database.PostgreSQLPlatform" ./ews/ranger-admin-services.sh 2>/dev/null; then
        sed -i.bak3 's/\(org\.apache\.ranger\.server\.tomcat\.EmbeddedServer\)/-Declipselink.target-database=org.eclipse.persistence.platform.database.PostgreSQLPlatform \1/g' ./ews/ranger-admin-services.sh 2>/dev/null && \
        echo "  ✓ Added before main class" || echo "  ⚠ Failed to add before main class"
    fi
    
    # Method 3: Add to JAVA_OPTS assignment in the script (if it exists)
    if ! grep -q "eclipselink.target-database=org.eclipse.persistence.platform.database.PostgreSQLPlatform" ./ews/ranger-admin-services.sh 2>/dev/null; then
        # Look for JAVA_OPTS= or export JAVA_OPTS= lines and append to them
        sed -i.bak4 's/\(JAVA_OPTS=\)\(".*"\)/\1\2 -Declipselink.target-database=org.eclipse.persistence.platform.database.PostgreSQLPlatform/g' ./ews/ranger-admin-services.sh 2>/dev/null || \
        sed -i.bak5 's/\(export JAVA_OPTS=\)\(".*"\)/\1\2 -Declipselink.target-database=org.eclipse.persistence.platform.database.PostgreSQLPlatform/g' ./ews/ranger-admin-services.sh 2>/dev/null || true
    fi
    
    # Verify the patch was applied
    if grep -q "eclipselink.target-database=org.eclipse.persistence.platform.database.PostgreSQLPlatform" ./ews/ranger-admin-services.sh 2>/dev/null; then
        echo "  ✓ PostgreSQL dialect property added to startup script"
    else
        echo "  ✗ WARNING: Failed to add PostgreSQL dialect to startup script"
        echo "  The property must be in the Java command line for it to work"
    fi
else
    echo "  ✓ PostgreSQL dialect property already in startup script"
fi

# CRITICAL: Verify configuration before starting
echo "Final configuration verification before starting Ranger Admin..."
echo "  Checking ranger-admin-site.xml..."
if [ -f "${CONF_DIR}/ranger-admin-site.xml" ]; then
    if grep -q "ranger.jpa.jdbc.dialect.*PostgreSQL" "${CONF_DIR}/ranger-admin-site.xml"; then
        echo "  ✓ ranger-admin-site.xml has PostgreSQL dialect"
    else
        echo "  ✗ WARNING: ranger-admin-site.xml missing PostgreSQL dialect!"
    fi
else
    echo "  ✗ ERROR: ranger-admin-site.xml not found!"
fi

echo "  Checking persistence.xml..."
if [ -f "${META_INF_DIR}/persistence.xml" ]; then
    if grep -q "eclipselink.target-database.*PostgreSQL" "${META_INF_DIR}/persistence.xml"; then
        echo "  ✓ persistence.xml has PostgreSQL dialect"
    else
        echo "  ✗ WARNING: persistence.xml missing PostgreSQL dialect!"
    fi
else
    echo "  ✗ ERROR: persistence.xml not found!"
fi

echo "  JAVA_OPTS: ${JAVA_OPTS}"
echo "  RANGER_ADMIN_OPTS: ${RANGER_ADMIN_OPTS}"

# CRITICAL: Check if ranger-admin-env.sh exists and might override JAVA_OPTS
ENV_SCRIPT="${RANGER_ADMIN_DIR}/ews/ranger-admin-env.sh"
if [ -f "$ENV_SCRIPT" ]; then
    echo "Checking ranger-admin-env.sh for JAVA_OPTS overrides..."
    if grep -q "JAVA_OPTS=" "$ENV_SCRIPT"; then
        echo "  WARNING: ranger-admin-env.sh sets JAVA_OPTS, may override our setting"
        echo "  This is why we patch the startup script directly"
    fi
fi

# The script uses ${HOSTNAME} in the Java command, so it must be set
# Even if env files unset it, we set it again right before calling the script
# JAVA_OPTS will be picked up by the script, but we've also patched the script directly
echo "Starting Ranger Admin service..."
HOSTNAME="ranger.nbd.demo" USER="ranger" JAVA_OPTS="${JAVA_OPTS}" RANGER_ADMIN_OPTS="${RANGER_ADMIN_OPTS}" ./ews/ranger-admin-services.sh start 2>&1

# Give it a moment to start
sleep 3

# Check if process started
RANGER_ADMIN_PID=$(ps -ef | grep -v grep | grep -i "org.apache.ranger.server.tomcat.EmbeddedServer" | awk '{print $2}' || echo "")

if [ -z "$RANGER_ADMIN_PID" ]; then
    echo "WARNING: Ranger Admin process not found immediately after start"
    echo "Checking log files for errors..."
    # Try to show any error from catalina.out
    for log_file in ${RANGER_ADMIN_LOG_DIR}/catalina.out ${XAPOLICYMGR_EWS_DIR}/logs/catalina.out; do
        if [ -f "$log_file" ]; then
            echo "=== Last 30 lines of $log_file ==="
            tail -30 "$log_file" 2>/dev/null || true
        fi
    done
else
    echo "Ranger Admin started with PID: $RANGER_ADMIN_PID"
    
    # CRITICAL: Verify the PostgreSQL dialect property is actually in the Java command line
    echo ""
    echo "=========================================="
    echo "Verifying PostgreSQL dialect in running process..."
    echo "=========================================="
    JAVA_CMD=$(ps -p "$RANGER_ADMIN_PID" -o args= 2>/dev/null || echo "")
    if [ -n "$JAVA_CMD" ]; then
        if echo "$JAVA_CMD" | grep -q "eclipselink.target-database.*PostgreSQL"; then
            echo "✓ PostgreSQL dialect property found in running Java process"
            echo "$JAVA_CMD" | grep -o "eclipselink.target-database=[^ ]*" | head -1
        else
            echo "✗ CRITICAL: PostgreSQL dialect property NOT FOUND in running Java process!"
            echo "  This is why you're seeing MySQL syntax errors (LIMIT $3, $4 instead of LIMIT $3 OFFSET $4)."
            echo ""
            echo "  Full Java command line:"
            echo "$JAVA_CMD" | tr ' ' '\n' | grep -E "(java|eclipselink|PostgreSQL|target-database)" | head -10
            echo ""
            echo "  The property should be: -Declipselink.target-database=org.eclipse.persistence.platform.database.PostgreSQLPlatform"
            echo ""
            echo "  Root cause analysis:"
            echo "  1. Checking if startup script was patched..."
            if grep -q "eclipselink.target-database.*PostgreSQL" ./ews/ranger-admin-services.sh 2>/dev/null; then
                echo "     ✓ Startup script has the property"
            else
                echo "     ✗ Startup script does NOT have the property - patching failed!"
            fi
            echo "  2. Checking if JAVA_OPTS is set..."
            if [ -n "$JAVA_OPTS" ] && echo "$JAVA_OPTS" | grep -q "eclipselink.target-database.*PostgreSQL"; then
                echo "     ✓ JAVA_OPTS has the property: $JAVA_OPTS"
            else
                echo "     ✗ JAVA_OPTS does NOT have the property"
            fi
            echo "  3. Run diagnostic script for full analysis:"
            echo "     docker exec nbd-ranger-admin /home/ranger/scripts/verify-ranger-config.sh"
        fi
    else
        echo "⚠ Could not get Java command line (process may have exited)"
    fi
    echo "=========================================="
    echo ""
fi

if [ "${SETUP_RANGER}" == "true" ]
then
  # Wait for Ranger Admin to become ready with proper health check
  echo "Waiting for Ranger Admin to be ready before creating services..."
  if [ -f "${RANGER_SCRIPTS}/wait-for-ranger.sh" ]; then
    chmod +x ${RANGER_SCRIPTS}/wait-for-ranger.sh
    ${RANGER_SCRIPTS}/wait-for-ranger.sh
  else
    # Fallback: Simple check if Ranger Admin process is running and port is listening
    # Note: curl is not available in the container, so we use process and port checks
    MAX_RETRIES=60
    RETRY_INTERVAL=5
    for i in $(seq 1 $MAX_RETRIES); do
      PROCESS_OK=false
      PORT_OK=false
      
      # Check if process is running
      if ps -ef | grep -v grep | grep -q "org.apache.ranger.server.tomcat.EmbeddedServer"; then
        PROCESS_OK=true
      fi
      
      # Check if port 6080 is listening
      if command -v nc >/dev/null 2>&1; then
        if nc -z localhost 6080 >/dev/null 2>&1; then
          PORT_OK=true
        fi
      else
        # Use bash TCP redirection as fallback
        if timeout 1 bash -c "echo > /dev/tcp/localhost/6080" 2>/dev/null; then
          PORT_OK=true
        fi
      fi
      
      if [ "$PROCESS_OK" = true ] && [ "$PORT_OK" = true ]; then
        echo "Ranger Admin is ready! (Process: OK, Port 6080: listening)"
        break
      fi
      
      echo "Attempt $i/$MAX_RETRIES: Waiting for Ranger Admin (process:${PROCESS_OK}, port:${PORT_OK})..."
      sleep $RETRY_INTERVAL
    done
  fi
  
  # Note: Service creation scripts can be run manually after Ranger Admin is ready
  # Default services can be created through the Ranger Admin UI or via REST API
fi

RANGER_ADMIN_PID=`ps -ef  | grep -v grep | grep -i "org.apache.ranger.server.tomcat.EmbeddedServer" | awk '{print $2}'`

if [ -z "$RANGER_ADMIN_PID" ]; then
  echo "ERROR: Ranger Admin process not found!"
  exit 1
fi

# Switch to ranger user for log tailing (if we started as root)
if [ "$(id -u)" = "0" ]; then
    # Drop to ranger user for the tail process
    exec su -s /bin/bash ranger -c "tail -f /var/log/ranger/catalina.out /opt/ranger/ranger-2.4.0-admin/ews/logs/catalina.out 2>/dev/null | head -1000" || {
        # If su fails, just tail as root
        tail -f /var/log/ranger/catalina.out /opt/ranger/ranger-2.4.0-admin/ews/logs/catalina.out 2>/dev/null || true
    }
    exit 0
fi

echo "Ranger Admin is running (PID: $RANGER_ADMIN_PID)"
echo "Tailing Ranger Admin logs..."

# Find and tail the main log files
RANGER_LOG_DIR="/opt/ranger/ranger-2.4.0-admin/ews/logs"
CATALINA_OUT="${RANGER_LOG_DIR}/catalina.out"
RANGER_LOG_DIR_VAR="/var/log/ranger"

# Wait a moment for logs to be created
sleep 3

# Function to tail logs and wait for process
tail_logs_and_wait() {
    # Start tailing logs in background
    if [ -f "$CATALINA_OUT" ]; then
        tail -f "$CATALINA_OUT" &
        CATALINA_TAIL_PID=$!
    fi
    
    # Tail ranger admin logs if they exist
    if [ -d "$RANGER_LOG_DIR_VAR" ] && ls ${RANGER_LOG_DIR_VAR}/ranger-admin-*.log 1> /dev/null 2>&1; then
        tail -f ${RANGER_LOG_DIR_VAR}/ranger-admin-*.log 2>/dev/null &
        RANGER_TAIL_PID=$!
    fi
    
    # Wait for Ranger Admin process to exit
    tail --pid=$RANGER_ADMIN_PID -f /dev/null
    
    # Clean up tail processes when Ranger Admin exits
    [ ! -z "$CATALINA_TAIL_PID" ] && kill $CATALINA_TAIL_PID 2>/dev/null || true
    [ ! -z "$RANGER_TAIL_PID" ] && kill $RANGER_TAIL_PID 2>/dev/null || true
}

# Start tailing logs
tail_logs_and_wait

