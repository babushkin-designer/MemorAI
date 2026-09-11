#!/bin/bash
set -euo pipefail

if ! command -v swiftlint >/dev/null 2>&1; then
    echo "SwiftLint is missing. Install it with: brew install swiftlint" >&2
    exit 1
fi

swiftlint lint --strict --quiet
