#!/bin/bash

# Script to enrich movies with OMDB data
# Usage: ./scripts/enrich_with_omdb.sh

# Load environment variables from .env file
if [ -f .env ]; then
  export $(cat .env | grep -v '^#' | xargs)
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

echo "API keys loaded successfully"
echo "OMDB API Key: ${OMDB_API_KEY:0:4}..." # Show first 4 chars for verification

# Run the enrichment
mix import_movies --enrich