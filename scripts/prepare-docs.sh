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
  source ~/.bashrc
  export PATH=$HOME/.foundry/bin:$PATH
  foundryup
fi

hardhat docgen

node scripts/gen-nav.js "$OUTDIR" > "$OUTDIR/../nav.adoc"