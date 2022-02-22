#!/usr/bin/env bash
# Make dependencies available
export DAPP_REMAPPINGS=$(cat remappings.txt)

export DAPP_SOLC_VERSION=0.8.12
export DAPP_LINK_TEST_LIBRARIES=0
export DAPP_TEST_VERBOSITY=1
export DAPP_TEST_SMTTIMEOUT=500000

# Optimize your contracts before deploying to reduce runtime execution costs.
# Check out the docs to learn more: https://docs.soliditylang.org/en/v0.8.9/using-the-compiler.html#optimizer-options
export DAPP_BUILD_OPTIMIZE=1
export DAPP_BUILD_OPTIMIZE_RUNS=200

slither . --compile-force-framework dapp
