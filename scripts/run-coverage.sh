#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_DIR="$ROOT_DIR/../Flutter_Apps/blablaragsandrigs"
DASHBOARD_DIR="$ROOT_DIR/dashboard"
SERVER_DIR="$ROOT_DIR/server"

mkdir -p "$ROOT_DIR/coverage"

echo "Generating Flutter coverage..."
if [ -d "$FLUTTER_DIR" ]; then
  (cd "$FLUTTER_DIR" && flutter test --coverage)
else
  echo "Flutter app directory not found: $FLUTTER_DIR"
fi

echo "Generating dashboard coverage..."
if [ -d "$DASHBOARD_DIR" ]; then
  (cd "$DASHBOARD_DIR" && npm run test:coverage)
else
  echo "Dashboard directory not found: $DASHBOARD_DIR"
fi

echo "Generating server coverage..."
if [ -d "$SERVER_DIR" ]; then
  (cd "$SERVER_DIR" && npm run test -- --coverage)
else
  echo "Server directory not found: $SERVER_DIR"
fi

echo "Coverage generation completed. Reports are in the individual project folders."
