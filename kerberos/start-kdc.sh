#!/bin/bash
set -e

REALM="${REALM:-SISHUO.DEMO}"
KDC_PASSWORD="${KDC_PASSWORD:-kdc123}"

# Initialize KDC if not already done
if [ ! -f /var/lib/krb5kdc/.initialized ]; then
    echo "Initializing Kerberos KDC for realm ${REALM}..."
    
    # Create realm
    kdb5_util create -r "${REALM}" -s -P "${KDC_PASSWORD}" || {
        echo "Realm may already exist, continuing..."
    }
    
    # Create admin principal
    kadmin.local -q "addprinc -pw admin123 admin/admin@${REALM}" || {
        echo "Admin principal may already exist, continuing..."
    }
    
    touch /var/lib/krb5kdc/.initialized
    echo "Kerberos KDC initialized!"
fi

# Start KDC
echo "Starting Kerberos KDC..."
exec /usr/sbin/krb5kdc -n

