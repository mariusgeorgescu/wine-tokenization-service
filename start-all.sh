#!/usr/bin/env bash
set -e

# Ensure only 0 or 2 arguments are accepted
if [ $# -ne 0 ] && [ $# -ne 2 ]; then
  echo "Usage: $0 [arg1 arg2]"
  exit 1
fi

# set basic auth for ipfs
if [ $# -ne 2 ]; then
  AUTH=$(echo -n "$1:$2" | base64)
else
  AUTH=$(echo -n "cardano:lovelace" | base64)
fi


# Config IPFS API
ipfs config --json API.HTTPHeaders.Access-Control-Allow-Origin "[\"*\"]"
ipfs config --json API.HTTPHeaders.Access-Control-Allow-Methods "[\"PUT\", \"GET\", \"POST\"]"
ipfs config --json API.HTTPHeaders.Access-Control-Allow-Credentials "[\"true\"]"
ipfs config --json API.HTTPHeaders.Authorization '["Basic '"$AUTH"'"]'


# Start IPFS daemon
ipfs daemon &

# Optional: Wait a few seconds for IPFS to fully initialize
sleep 5

# Start your server, passing along any given arguments
exec server "$@"