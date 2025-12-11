#!/bin/bash
#
# Generate password hashes for LDIF files
# This script uses slappasswd to generate SSHA password hashes
#
# Usage: ./generate-ldap-passwords.sh [password]
# Default password: password123

PASSWORD="${1:-password123}"

if ! command -v slappasswd &> /dev/null; then
    echo "Error: slappasswd command not found."
    echo "Please install openldap-utils package:"
    echo "  Ubuntu/Debian: sudo apt-get install ldap-utils"
    echo "  RHEL/CentOS: sudo yum install openldap-clients"
    exit 1
fi

echo "Generating password hash for: ${PASSWORD}"
echo ""
HASH=$(slappasswd -s "${PASSWORD}")
echo "Password hash: ${HASH}"
echo ""
echo "You can use this in your LDIF files like:"
echo "  userPassword: ${HASH}"
echo ""
echo "Or update LDIF files automatically:"
read -p "Update LDIF files with this hash? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    # Update LDIF files
    for file in ../ldap/ldif/*.ldif; do
        if [ -f "$file" ]; then
            # Replace {SSHA}password123 with actual hash
            sed -i.bak "s/{SSHA}password123/${HASH}/g" "$file"
            echo "Updated: $file"
        fi
    done
    echo "Done! Backup files created with .bak extension"
fi

