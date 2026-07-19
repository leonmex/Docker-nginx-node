#!/bin/bash
set -e

# Define paths
CERTS_DIR="$(dirname "$0")/../nginx/certs"

echo "Creating certificate directory..."
mkdir -p "$CERTS_DIR"

echo "Generating self-signed SSL certificate for webapp-node.io..."
openssl req -nodes -new -x509 -keyout "$CERTS_DIR/server.key" -out "$CERTS_DIR/server.crt" -days 3650 -subj "/CN=webapp-node.io/O=NodeNginxClean/C=US"

echo "SSL Certificate generated successfully in $CERTS_DIR!"
ls -la "$CERTS_DIR"
