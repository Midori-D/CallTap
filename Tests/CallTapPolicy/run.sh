#!/usr/bin/env bash
set -euo pipefail
CALLTAP_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CALLTAP_TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$CALLTAP_TEST_DIR"' EXIT
swiftc "$CALLTAP_ROOT/iCTRLUITests/CallTapPolicy.swift" \
  "$CALLTAP_ROOT/Tests/CallTapPolicy/main.swift" \
  -o "$CALLTAP_TEST_DIR/calltap-policy-tests"
"$CALLTAP_TEST_DIR/calltap-policy-tests"
