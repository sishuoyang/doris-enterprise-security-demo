#!/bin/bash
# Diagnostic script to verify Ranger Admin PostgreSQL configuration
# Run this inside the Ranger Admin container to troubleshoot dialect issues

echo "=========================================="
echo "Ranger Admin Configuration Diagnostic"
echo "=========================================="
echo ""

RANGER_ADMIN_DIR="/opt/ranger/ranger-2.4.0-admin"
CONF_DIR="${RANGER_ADMIN_DIR}/ews/webapp/WEB-INF/classes/conf"
META_INF_DIR="${RANGER_ADMIN_DIR}/ews/webapp/WEB-INF/classes/META-INF"

echo "1. Checking ranger-admin-site.xml..."
if [ -f "${CONF_DIR}/ranger-admin-site.xml" ]; then
    echo "   ✓ File exists: ${CONF_DIR}/ranger-admin-site.xml"
    echo "   Checking for ranger.jpa.jdbc.dialect property:"
    if grep -q "ranger.jpa.jdbc.dialect" "${CONF_DIR}/ranger-admin-site.xml"; then
        echo "   ✓ Property found:"
        grep -A 2 "ranger.jpa.jdbc.dialect" "${CONF_DIR}/ranger-admin-site.xml" | head -3
    else
        echo "   ✗ Property NOT FOUND!"
    fi
    echo "   Checking JDBC URL:"
    grep -A 2 "ranger.jpa.jdbc.url" "${CONF_DIR}/ranger-admin-site.xml" | head -3
else
    echo "   ✗ File NOT FOUND: ${CONF_DIR}/ranger-admin-site.xml"
fi
echo ""

echo "2. Checking persistence.xml..."
if [ -f "${META_INF_DIR}/persistence.xml" ]; then
    echo "   ✓ File exists: ${META_INF_DIR}/persistence.xml"
    echo "   Checking for PostgreSQL dialect:"
    if grep -q "eclipselink.target-database.*PostgreSQL" "${META_INF_DIR}/persistence.xml"; then
        echo "   ✓ PostgreSQL dialect found:"
        grep "eclipselink.target-database" "${META_INF_DIR}/persistence.xml" | head -2
    else
        echo "   ✗ PostgreSQL dialect NOT FOUND!"
        echo "   Found:"
        grep "eclipselink.target-database" "${META_INF_DIR}/persistence.xml" || echo "   (no eclipselink.target-database property found)"
    fi
else
    echo "   ✗ File NOT FOUND: ${META_INF_DIR}/persistence.xml"
fi
echo ""

echo "3. Checking startup script (ranger-admin-services.sh)..."
STARTUP_SCRIPT="${RANGER_ADMIN_DIR}/ews/ranger-admin-services.sh"
if [ -f "$STARTUP_SCRIPT" ]; then
    echo "   ✓ File exists: $STARTUP_SCRIPT"
    echo "   Checking for PostgreSQL dialect in Java command:"
    if grep -q "eclipselink.target-database.*PostgreSQL" "$STARTUP_SCRIPT"; then
        echo "   ✓ PostgreSQL dialect found in startup script:"
        grep "eclipselink.target-database.*PostgreSQL" "$STARTUP_SCRIPT" | head -2
    else
        echo "   ✗ PostgreSQL dialect NOT FOUND in startup script!"
    fi
    echo "   Checking Java command construction:"
    grep -A 5 "java.*org.apache.ranger" "$STARTUP_SCRIPT" | head -10 || echo "   (Java command pattern not found)"
else
    echo "   ✗ File NOT FOUND: $STARTUP_SCRIPT"
fi
echo ""

echo "4. Checking environment variables..."
echo "   JAVA_OPTS: ${JAVA_OPTS:-<not set>}"
echo "   RANGER_ADMIN_OPTS: ${RANGER_ADMIN_OPTS:-<not set>}"
echo ""

echo "5. Checking running Java process..."
RANGER_PID=$(ps -ef | grep -v grep | grep -i "org.apache.ranger.server.tomcat.EmbeddedServer" | awk '{print $2}' || echo "")
if [ -n "$RANGER_PID" ]; then
    echo "   ✓ Ranger Admin process found (PID: $RANGER_PID)"
    echo "   Java command line:"
    ps -p "$RANGER_PID" -o args= | head -1
    echo ""
    echo "   Checking for PostgreSQL dialect in process:"
    if ps -p "$RANGER_PID" -o args= | grep -q "eclipselink.target-database.*PostgreSQL"; then
        echo "   ✓ PostgreSQL dialect property found in running process"
        ps -p "$RANGER_PID" -o args= | grep -o "eclipselink.target-database=[^ ]*" | head -1
    else
        echo "   ✗ PostgreSQL dialect property NOT FOUND in running process!"
        echo "   This is the root cause - the property is not being passed to Java"
    fi
else
    echo "   ⚠ Ranger Admin process not running"
fi
echo ""

echo "6. Checking Spring applicationContext.xml (if accessible)..."
APPLICATION_CONTEXT="${RANGER_ADMIN_DIR}/ews/webapp/WEB-INF/classes/META-INF/applicationContext.xml"
if [ -f "$APPLICATION_CONTEXT" ]; then
    echo "   ✓ File exists: $APPLICATION_CONTEXT"
    echo "   Checking databasePlatform property:"
    if grep -q "databasePlatform" "$APPLICATION_CONTEXT"; then
        grep -A 2 "databasePlatform" "$APPLICATION_CONTEXT" | head -5
    else
        echo "   (databasePlatform property not found)"
    fi
else
    echo "   ⚠ File not accessible (may be in JAR)"
fi
echo ""

echo "7. Checking ranger-admin-default-site.xml..."
DEFAULT_SITE="${CONF_DIR}/ranger-admin-default-site.xml"
if [ -f "$DEFAULT_SITE" ]; then
    echo "   ✓ File exists: $DEFAULT_SITE"
    echo "   Checking for dialect default:"
    if grep -q "ranger.jpa.jdbc.dialect" "$DEFAULT_SITE"; then
        echo "   Default dialect setting:"
        grep -A 2 "ranger.jpa.jdbc.dialect" "$DEFAULT_SITE" | head -3
        echo "   ⚠ WARNING: If this is MySQL, it will override ranger-admin-site.xml!"
    else
        echo "   (no dialect property in default config)"
    fi
else
    echo "   ⚠ File not found (may be in conf.dist)"
fi
echo ""

echo "8. Checking startup script (ranger-admin-services.sh) for dialect property..."
STARTUP_SCRIPT="${RANGER_ADMIN_DIR}/ews/ranger-admin-services.sh"
if [ -f "$STARTUP_SCRIPT" ]; then
    echo "   Checking if PostgreSQL dialect is in Java command:"
    if grep -q "eclipselink.target-database.*PostgreSQL" "$STARTUP_SCRIPT"; then
        echo "   ✓ PostgreSQL dialect found in startup script:"
        grep "eclipselink.target-database.*PostgreSQL" "$STARTUP_SCRIPT" | head -2
    else
        echo "   ✗ PostgreSQL dialect NOT FOUND in startup script!"
        echo "   This means the property won't be passed to Java"
    fi
    
    echo "   Checking Java command construction:"
    # Look for the actual java command line
    if grep -q "org.apache.ranger.server.tomcat.EmbeddedServer" "$STARTUP_SCRIPT"; then
        echo "   Java command pattern found. Checking for dialect:"
        grep -B 5 -A 5 "org.apache.ranger.server.tomcat.EmbeddedServer" "$STARTUP_SCRIPT" | grep -E "(java|eclipselink|PostgreSQL)" | head -5
    fi
else
    echo "   ✗ Startup script not found!"
fi
echo ""

echo "9. Checking environment files that might override JAVA_OPTS..."
ENV_SCRIPT="${RANGER_ADMIN_DIR}/ews/ranger-admin-env.sh"
if [ -f "$ENV_SCRIPT" ]; then
    echo "   ✓ ranger-admin-env.sh exists"
    if grep -q "JAVA_OPTS=" "$ENV_SCRIPT"; then
        echo "   ⚠ WARNING: ranger-admin-env.sh sets JAVA_OPTS:"
        grep "JAVA_OPTS=" "$ENV_SCRIPT" | head -3
        echo "   This may override our JAVA_OPTS setting!"
    else
        echo "   (no JAVA_OPTS override found)"
    fi
else
    echo "   (ranger-admin-env.sh not found)"
fi
echo ""

echo "=========================================="
echo "Diagnostic Complete"
echo "=========================================="
echo ""
echo "If PostgreSQL dialect is missing from the running process,"
echo "the root cause is that the property is not being passed to Java."
echo "Check the startup script patching and JAVA_OPTS handling above."
