#!/bin/bash
set -e

KEYSTORE_PASSWORD="changeit"
KEYSTORE_DIR="./ssl/keystores"
TRUSTSTORE_DIR="./ssl/truststores"

mkdir -p "$KEYSTORE_DIR" "$TRUSTSTORE_DIR"

# Generate keystore for NameNode
keytool -genkeypair -alias namenode -keyalg RSA -keysize 2048 \
  -dname "CN=namenode.nbd.demo, OU=Hadoop, O=NBD Demo, L=Unknown, ST=Unknown, C=US" \
  -keystore "$KEYSTORE_DIR/namenode.keystore" \
  -storepass "$KEYSTORE_PASSWORD" \
  -keypass "$KEYSTORE_PASSWORD" \
  -validity 365

# Generate keystore for DataNode
keytool -genkeypair -alias datanode -keyalg RSA -keysize 2048 \
  -dname "CN=datanode1.nbd.demo, OU=Hadoop, O=NBD Demo, L=Unknown, ST=Unknown, C=US" \
  -keystore "$KEYSTORE_DIR/datanode.keystore" \
  -storepass "$KEYSTORE_PASSWORD" \
  -keypass "$KEYSTORE_PASSWORD" \
  -validity 365

# Export certificates
keytool -exportcert -alias namenode \
  -keystore "$KEYSTORE_DIR/namenode.keystore" \
  -storepass "$KEYSTORE_PASSWORD" \
  -file "$KEYSTORE_DIR/namenode.crt"

keytool -exportcert -alias datanode \
  -keystore "$KEYSTORE_DIR/datanode.keystore" \
  -storepass "$KEYSTORE_PASSWORD" \
  -file "$KEYSTORE_DIR/datanode.crt"

# Create truststores
keytool -importcert -alias namenode \
  -file "$KEYSTORE_DIR/namenode.crt" \
  -keystore "$TRUSTSTORE_DIR/namenode.truststore" \
  -storepass "$KEYSTORE_PASSWORD" \
  -noprompt

keytool -importcert -alias datanode \
  -file "$KEYSTORE_DIR/datanode.crt" \
  -keystore "$TRUSTSTORE_DIR/datanode.truststore" \
  -storepass "$KEYSTORE_PASSWORD" \
  -noprompt

# Import both into a common truststore
keytool -importcert -alias namenode \
  -file "$KEYSTORE_DIR/namenode.crt" \
  -keystore "$TRUSTSTORE_DIR/common.truststore" \
  -storepass "$KEYSTORE_PASSWORD" \
  -noprompt

keytool -importcert -alias datanode \
  -file "$KEYSTORE_DIR/datanode.crt" \
  -keystore "$TRUSTSTORE_DIR/common.truststore" \
  -storepass "$KEYSTORE_PASSWORD" \
  -noprompt

echo "SSL certificates generated successfully!"
echo "Keystores: $KEYSTORE_DIR"
echo "Truststores: $TRUSTSTORE_DIR"
