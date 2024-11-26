#!/usr/bin/env bash

set -euo pipefail
# shopt -s globstar

OUTDIR="$(node -p 'require("./docs/config.js").outputDir')"

if [ ! -d node_modules ]; then
  npm ci
fi

rm -rf "$OUTDIR"

# Check if forge is installed
if ! command -v forge &> /dev/null; then
  curl -L https://foundry.paradigm.xyz | bash

  if ! grep -q 'export PATH="$HOME/.foundry/bin:$PATH"' "$PROFILE"; then
      echo 'export PATH="$HOME/.foundry/bin:$PATH"' >> "$PROFILE"
  fi

  source "$PROFILE"

  if foundryup; then
      echo "Foundry installation successful!"
  else
      echo "Foundry installation failed."
      exit 1
  fi
fi

hardhat docgen

node scripts/gen-nav.js "$OUTDIR" > "$OUTDIR/../nav.adoc"