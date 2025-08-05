#!/bin/bash

# Script to reseed movie lists from hardcoded canonical lists
# This is useful when the movie_lists table gets cleared but you want to restore defaults

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}🌱 Reseeding default movie lists...${NC}"
echo ""

# Run the seeding task
mix seed_movie_lists

echo ""
echo -e "${GREEN}✅ Movie lists reseeded successfully!${NC}"
echo ""
echo "You can now use these lists for imports:"
echo "  - Via UI: http://localhost:4001/import"
echo "  - Via Mix: mix import_canonical --list 1001_movies"