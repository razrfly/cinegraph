#!/bin/bash

# Complete import script with environment variables
# Usage: ./scripts/import_with_env.sh [--fresh|--reset] [--pages N]

# Load environment variables from .env file
if [ -f .env ]; then
  set -a  # automatically export all variables
  source .env
  set +a
fi

# Verify API keys are loaded
if [ -z "$TMDB_API_KEY" ]; then
  echo "Error: TMDB_API_KEY not found in .env file"
  exit 1
fi

if [ -z "$OMDB_API_KEY" ]; then
  echo "Error: OMDB_API_KEY not found in .env file"
  exit 1
fi

echo "🎬 Cinegraph Import Process"
echo "=========================="
echo "TMDB API Key: ${TMDB_API_KEY:0:4}..." # Show first 4 chars
echo "OMDB API Key: ${OMDB_API_KEY:0:4}..." # Show first 4 chars
echo ""

# Pass all arguments to the mix task
mix import_movies "$@"