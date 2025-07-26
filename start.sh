#!/bin/bash

# Load environment variables from .env file
if [ -f .env ]; then
  set -a  # automatically export all variables
  source .env
  set +a
fi

# Start Phoenix server
mix phx.server