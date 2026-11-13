#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/wren-security.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
swiftc Sources/Wren/Keychain.swift Tests/AppSecurity/KeychainRegression.swift -o "$build_dir/keychain-tests"
"$build_dir/keychain-tests"
