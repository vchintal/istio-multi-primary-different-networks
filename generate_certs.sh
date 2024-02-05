#!/bin/sh

set -ex

clusters=(cluster1 cluster2)

if ! [ -x "$(command -v step)" ]; then
    echo 'Error: Install the smallstep cli (https://github.com/smallstep/cli)'
    exit 1
fi

# Base directory for certificates
certs_base_dir="$(pwd)/certs"

# Ensure the certs directory exists
mkdir -p "${certs_base_dir}"

# Loop through all provided cluster names
for cluster_name in ${clusters[@]}; do
    
    # Define the directory paths for each cluster's certificates
    cert_dir="${certs_base_dir}/${cluster_name}"
    
    # Create the cert directory for the cluster if it doesn't exist
    mkdir -p "${cert_dir}"
    
    # Root CA
    if [ ! -f "${certs_base_dir}/root-cert.pem" ]; then
        step certificate create root-ca "${certs_base_dir}/root-cert.pem" "${certs_base_dir}/root-ca.key" \
            --profile root-ca --no-password --insecure \
            --not-after 87600h --kty RSA 
    fi
    
    # Intermediate CA
    if [ ! -f "${cert_dir}/ca-cert.pem" ]; then
        step certificate create "${cluster_name}-ca" "${cert_dir}/ca-cert.pem" "${cert_dir}/ca-key.pem" \
            --ca "${certs_base_dir}/root-cert.pem" --ca-key "${certs_base_dir}/root-ca.key" \
            --profile intermediate-ca --not-after 87600h --no-password --insecure \
            --kty RSA 

        # Certificate Chain
        cp  "${certs_base_dir}/root-cert.pem" "${cert_dir}/root-cert.pem" 
        cat "${cert_dir}/ca-cert.pem" "${cert_dir}/root-cert.pem" > "${cert_dir}/cert-chain.pem"
    else
        echo "Certificates already exist for ${cluster_name}, skipping generation."
    fi
done

echo "Certificates generated successfully!"
