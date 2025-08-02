#!/bin/bash

# Helper script to run any command with .env loaded
# Usage: ./scripts/run_with_env.sh <command>

# Load environment variables from .env file
if [ -f .env ]; then
  set -a  # automatically export all variables
  source .env
  set +a
else
  echo "Error: .env file not found!"
  echo "Please create a .env file with your API keys:"
  echo "  TMDB_API_KEY=your_tmdb_key"
  echo "  OMDB_API_KEY=your_omdb_key"
  exit 1
fi

# Run the command passed as arguments
"$@"