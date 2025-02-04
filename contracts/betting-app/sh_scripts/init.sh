#!/bin/sh

set -e

echo "##### Creating a new Aptos account #####"

aptos init \
  --network mainnet \
  --profile mainnet-profile-1
