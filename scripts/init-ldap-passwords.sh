#!/bin/bash
#
# Initialize LDAP user passwords after OpenLDAP container starts
# This script connects to the running OpenLDAP container and sets passwords
#
# Usage: ./init-ldap-passwords.sh

set -euo pipefail

LDAP_HOST="${LDAP_HOST:-localhost}"
LDAP_PORT="${LDAP_PORT:-389}"
LDAP_ADMIN_DN="${LDAP_ADMIN_DN:-cn=admin,dc=nbd,dc=demo}"
LDAP_ADMIN_PW="${LDAP_ADMIN_PW:-admin123}"
PASSWORD="${PASSWORD:-password123}"

# Generate password hash
if command -v slappasswd &> /dev/null; then
    PASSWORD_HASH=$(slappasswd -s "${PASSWORD}")
    echo "Generated password hash for: ${PASSWORD}"
else
    echo "Warning: slappasswd not found. Using plain text (may not work)."
    PASSWORD_HASH="{PLAIN}${PASSWORD}"
fi

# Function to set user password
set_user_password() {
    local user_dn=$1
    local username=$2
    
    echo "Setting password for ${username}..."
    
    # Create temporary LDIF file
    local tmp_ldif=$(mktemp)
    cat > "${tmp_ldif}" <<EOF
dn: ${user_dn}
changetype: modify
replace: userPassword
userPassword: ${PASSWORD_HASH}
EOF
    
    # Apply change
    ldapmodify -x -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
        -D "${LDAP_ADMIN_DN}" \
        -w "${LDAP_ADMIN_PW}" \
        -f "${tmp_ldif}" || {
        echo "Warning: Failed to set password for ${username}"
    }
    
    rm -f "${tmp_ldif}"
}

echo "=========================================="
echo "LDAP Password Initialization"
echo "=========================================="
echo "LDAP Host: ${LDAP_HOST}:${LDAP_PORT}"
echo "Admin DN: ${LDAP_ADMIN_DN}"
echo ""

# Wait for LDAP to be ready
echo "Waiting for LDAP to be ready..."
for i in {1..30}; do
    if ldapsearch -x -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
        -b "dc=nbd,dc=demo" \
        -D "${LDAP_ADMIN_DN}" \
        -w "${LDAP_ADMIN_PW}" \
        -s base > /dev/null 2>&1; then
        echo "LDAP is ready!"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "Error: LDAP not ready after 30 attempts"
        exit 1
    fi
    sleep 1
done

# Set passwords for all users
set_user_password "uid=admin,ou=users,dc=nbd,dc=demo" "admin"
set_user_password "uid=analyst1,ou=users,dc=nbd,dc=demo" "analyst1"
set_user_password "uid=analyst2,ou=users,dc=nbd,dc=demo" "analyst2"
set_user_password "uid=dataengineer1,ou=users,dc=nbd,dc=demo" "dataengineer1"

echo ""
echo "=========================================="
echo "Password initialization complete!"
echo "=========================================="
echo ""
echo "Test authentication:"
echo "  ldapwhoami -x -H ldap://${LDAP_HOST}:${LDAP_PORT} \\"
echo "    -D 'uid=analyst1,ou=users,dc=nbd,dc=demo' \\"
echo "    -w ${PASSWORD}"

