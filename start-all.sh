#!/usr/bin/env bash
set -e

# Ensure only 0 or 2 arguments are accepted
if [ $# -ne 0 ] && [ $# -ne 2 ]; then
  echo "Usage: $0 [user pass]"
  exit 1
fi

# set basic auth for ipfs
if [ $# -ne 2 ]; then
  USER="cardano"
  PASS="lovelace"
else
  USER=$1
  PASS=$2
fi

# Config IPFS API
ipfs config Addresses.API /ip4/0.0.0.0/tcp/5001
ipfs config Addresses.Gateway /ip4/0.0.0.0/tcp/8080
ipfs config --json API.HTTPHeaders.Access-Control-Allow-Origin "[\"*\"]"
ipfs config --json API.HTTPHeaders.Access-Control-Allow-Methods "[\"PUT\", \"GET\", \"POST\"]"
ipfs config --json API.HTTPHeaders.Access-Control-Allow-Credentials "[\"true\"]"
ipfs config --json API.Authorizations '{
  "cardano": {
    "AuthSecret": "basic:'$USER':'$PASS'",
    "AllowedPaths": ["/api/v0"]
  }
}'


# Start IPFS daemon
ipfs daemon &

# Optional: Wait a few seconds for IPFS to fully initialize
sleep 1

# Start your server, passing along any given arguments
exec server $USER $PASS