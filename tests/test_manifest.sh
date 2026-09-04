#!/bin/bash
# ==============================================================================
# Validation Test: Omarchy Plugin Manifest
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🧪 Running plugin manifest validation..."

if command -v omarchy-plugin-validate >/dev/null 2>&1; then
  omarchy-plugin-validate "$PROJECT_ROOT"
  echo "  ✅ Manifest conforms to Omarchy plugin registry schema."
else
  # Fallback manual validation if omarchy-plugin-validate is not in environment
  MANIFEST="$PROJECT_ROOT/manifest.json"
  jq -e '.schemaVersion == 1' "$MANIFEST" >/dev/null
  jq -e 'has("id") and has("name") and has("version") and has("kinds") and has("entryPoints")' "$MANIFEST" >/dev/null
  echo "  ✅ Manifest JSON syntax and required fields validated."
fi

echo "🎉 Plugin validation passed successfully!"
