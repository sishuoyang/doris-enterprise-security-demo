#!/bin/bash
#
# Test script to verify HDFS access with Kerberos authentication
# This script runs inside the test client container

set -euo pipefail

REALM="${REALM:-SISHUO.DEMO}"
TEST_USER="${TEST_USER:-analyst1}"
PASSWORD="${PASSWORD:-password123}"
NAMENODE="${NAMENODE:-namenode.nbd.demo:9000}"

echo "=========================================="
echo "HDFS Kerberos Authentication Test"
echo "=========================================="
echo "Realm: ${REALM}"
echo "User: ${TEST_USER}"
echo "NameNode: ${NAMENODE}"
echo ""

# Check if krb5.conf exists (try multiple locations)
KRB5_CONF=""
if [ -f /etc/krb5.conf ]; then
    KRB5_CONF="/etc/krb5.conf"
elif [ -f ./kerberos/krb5.conf ]; then
    KRB5_CONF="./kerberos/krb5.conf"
    export KRB5_CONFIG="${KRB5_CONF}"
elif [ -f ../kerberos/krb5.conf ]; then
    KRB5_CONF="../kerberos/krb5.conf"
    export KRB5_CONFIG="${KRB5_CONF}"
elif [ -f "${PWD}/kerberos/krb5.conf" ]; then
    KRB5_CONF="${PWD}/kerberos/krb5.conf"
    export KRB5_CONFIG="${KRB5_CONF}"
else
    echo "ERROR: krb5.conf not found in any expected location"
    echo "Searched: /etc/krb5.conf, ./kerberos/krb5.conf, ../kerberos/krb5.conf"
    exit 1
fi

echo "Using krb5.conf: ${KRB5_CONF}"

# Check if keytab exists (optional - we'll use password auth for testing)
if [ -f /etc/security/keytabs/${TEST_USER}.keytab ]; then
    echo "Using keytab authentication..."
    kinit -kt /etc/security/keytabs/${TEST_USER}.keytab ${TEST_USER}@${REALM}
else
    echo "Using password authentication..."
    echo "${PASSWORD}" | kinit ${TEST_USER}@${REALM}
fi

# Verify ticket
echo ""
echo "Verifying Kerberos ticket:"
klist

# Test HDFS access
echo ""
echo "Testing HDFS access..."
echo "HDFS URI: hdfs://${NAMENODE}"

# Check if HDFS client is available
if command -v hdfs &> /dev/null; then
    echo ""
    echo "1. Listing HDFS root directory:"
    hdfs dfs -ls hdfs://${NAMENODE}/ || {
        echo "ERROR: Failed to list HDFS root"
        exit 1
    }
    
    echo ""
    echo "2. Creating test directory:"
    TEST_DIR="/tmp/test-kerberos-$(date +%s)"
    hdfs dfs -mkdir -p hdfs://${NAMENODE}${TEST_DIR} || {
        echo "ERROR: Failed to create test directory"
        exit 1
    }
    
    echo ""
    echo "3. Creating test file:"
    echo "Hello from Kerberos-authenticated client!" > /tmp/test.txt
    hdfs dfs -put /tmp/test.txt hdfs://${NAMENODE}${TEST_DIR}/test.txt || {
        echo "ERROR: Failed to upload test file"
        exit 1
    }
    
    echo ""
    echo "4. Reading test file:"
    hdfs dfs -cat hdfs://${NAMENODE}${TEST_DIR}/test.txt || {
        echo "ERROR: Failed to read test file"
        exit 1
    }
    
    echo ""
    echo "5. Listing test directory:"
    hdfs dfs -ls hdfs://${NAMENODE}${TEST_DIR} || {
        echo "ERROR: Failed to list test directory"
        exit 1
    }
    
    echo ""
    echo "6. Cleaning up test directory:"
    hdfs dfs -rm -r hdfs://${NAMENODE}${TEST_DIR} || {
        echo "WARNING: Failed to clean up test directory"
    }
    
    echo ""
    echo "=========================================="
    echo "✅ All HDFS Kerberos tests passed!"
    echo "=========================================="
else
    echo "WARNING: hdfs command not found"
    echo ""
    echo "To run full HDFS tests, please:"
    echo "1. Run the test inside the test client container:"
    echo "   docker-compose up hdfs-test-client"
    echo "   OR"
    echo "2. Install Hadoop client tools on your system"
    echo ""
    echo "Note: The hdfs command is available inside the test client container"
    echo "      which has Hadoop installed and configured."
    
    # Try WebHDFS if available (basic connectivity test)
    if command -v curl &> /dev/null; then
        echo ""
        echo "Testing NameNode Web UI connectivity..."
        # Note: With Kerberos enabled, HDFS typically uses HTTPS_ONLY policy
        # Try HTTP first, then HTTPS
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 http://localhost:9870/ 2>&1 | tail -1)
        if [ "${HTTP_CODE}" = "000" ] || [ -z "${HTTP_CODE}" ]; then
            # Try HTTPS (required when Kerberos is enabled)
            HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" --connect-timeout 2 https://localhost:9871/ 2>&1 | tail -1)
        fi
        
        if [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "401" ] || [ "${HTTP_CODE}" = "403" ] || [ "${HTTP_CODE}" = "307" ]; then
            echo "✅ NameNode Web UI is accessible (HTTP ${HTTP_CODE})"
            if [ "${HTTP_CODE}" != "200" ]; then
                echo "   Note: ${HTTP_CODE} is expected with Kerberos authentication enabled"
            fi
        elif [ "${HTTP_CODE}" = "000" ] || [ -z "${HTTP_CODE}" ]; then
            echo "⚠️  NameNode Web UI is not accessible from host (connection failed)"
            echo ""
            echo "This is expected when running the script on the host machine."
            echo "The script is designed to run inside the test client container where:"
            echo "  - The 'hdfs' command is available"
            echo "  - Network hostnames resolve correctly"
            echo "  - All dependencies are installed"
            echo ""
            echo "To run the full test suite, use:"
            echo "  docker-compose up hdfs-test-client"
        else
            echo "⚠️  NameNode Web UI returned HTTP ${HTTP_CODE}"
        fi
    fi
fi

