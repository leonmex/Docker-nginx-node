#!/bin/sh
set -e

echo "Starting webapp entrypoint..."

# Ensure we are in the correct directory
cd /usr/src/app

# Install dependencies if node_modules is missing
if [ ! -d "node_modules" ]; then
  echo "node_modules not found. Installing dependencies..."
  npm install
else
  echo "node_modules found. Skipping npm install."
fi

# Run the PDF parsing script
if [ -f "scripts/parse-pdf.mjs" ]; then
  echo "Running PDF parsing script..."
  node scripts/parse-pdf.mjs
else
  echo "Warning: scripts/parse-pdf.mjs not found. Skipping PDF parsing."
fi

# Determine how to start the app
if [ "$1" = "tail" ] && [ "$2" = "-f" ] && [ "$3" = "/dev/null" ]; then
  if [ "$NODE_ENV" = "development" ]; then
    echo "Running in development mode. Starting Astro dev server..."
    exec npm run dev -- --host 0.0.0.0 --port 4321
  else
    echo "Running in production/standby mode. Executing CMD..."
    exec "$@"
  fi
else
  echo "Executing command: $@"
  exec "$@"
fi
