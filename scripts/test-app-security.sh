#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift_target="$(uname -m)-apple-macosx14.0"
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/wren-security.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
swiftc -target "$swift_target" Sources/Wren/Keychain.swift Tests/AppSecurity/KeychainRegression.swift -o "$build_dir/keychain-tests"
"$build_dir/keychain-tests"
# Use the actual reader, including its SwiftUI coordinator and WebKit configuration, with synthetic HTML.
python3 Tests/WrenKitTests/Fixtures/Security/redirect-server.py "$build_dir/ports.json" &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; rm -rf "$build_dir"' EXIT
for attempt in {1..300}; do
  test -s "$build_dir/ports.json" && break
  sleep 0.1
done
test -s "$build_dir/ports.json"
swiftc -target "$swift_target" -emit-library -emit-module -module-name WrenKit Sources/WrenKit/*.swift \
  -emit-module-path "$build_dir/WrenKit.swiftmodule" -o "$build_dir/libWrenKit.dylib"
swiftc -target "$swift_target" -I "$build_dir" -L "$build_dir" -lWrenKit -Xlinker -rpath -Xlinker "$build_dir" \
  Sources/Wren/MessageWebView.swift Tests/AppSecurity/MessageWebViewRegression.swift -o "$build_dir/reader-tests"
"$build_dir/reader-tests" "$build_dir/ports.json"
