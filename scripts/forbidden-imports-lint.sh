#!/usr/bin/env bash
set -euo pipefail

# Fails the build if any forbidden networking API sneaks into Sources/.
# See SYSTEM-DESIGN.md §11 / §18.3 — the "your files never leave your Mac"
# promise is only true if these are structurally absent, not just avoided.

FORBIDDEN='URLSession|URLRequest|NWConnection|import Network'

if grep -rnE "$FORBIDDEN" Sources/ ; then
    echo ""
    echo "FORBIDDEN NETWORK IMPORT detected in Sources/."
    echo "See SYSTEM-DESIGN.md §11.1 / §18.3."
    exit 1
fi

echo "forbidden-imports-lint: OK"
