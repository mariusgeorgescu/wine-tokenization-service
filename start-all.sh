#!/usr/bin/env bash
set -e

# Ensure only 0 or 2 arguments are accepted
if [ $# -ne 0 ] && [ $# -ne 2 ]; then
  echo "Usage: $0 [arg1 arg2]"
  exit 1
fi

ipfs daemon --init &

# Optional: Wait a few seconds for IPFS to be ready,
# or poll with a simple check if you need to ensure IPFS is fully running.
sleep 5

# Start your Haskell server (in the foreground)
exec server "$@"
