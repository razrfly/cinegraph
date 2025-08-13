#!/bin/bash

# Script to clear all data from the Cinegraph database
# This is useful for testing imports with a clean slate

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Load environment variables
source .env

# Extract connection details from DATABASE_URL
if [[ -z "$SUPABASE_DATABASE_URL" ]]; then
    echo -e "${RED}Error: SUPABASE_DATABASE_URL not found in .env${NC}"
    exit 1
fi

# Validate DATABASE_URL format
if [[ ! "$SUPABASE_DATABASE_URL" =~ ^postgresql:// ]]; then
    echo -e "${RED}Error: Invalid DATABASE_URL format${NC}"
    exit 1
fi

# Parse the DATABASE_URL
DB_HOST=$(echo $SUPABASE_DATABASE_URL | sed -E 's/.*@([^:]+):.*/\1/')
DB_PORT=$(echo $SUPABASE_DATABASE_URL | sed -E 's/.*:([0-9]+)\/.*/\1/')
DB_NAME=$(echo $SUPABASE_DATABASE_URL | sed -E 's/.*\/([^?]+).*/\1/')
DB_USER=$(echo $SUPABASE_DATABASE_URL | sed -E 's/postgresql:\/\/([^:]+):.*/\1/')
DB_PASS=$(echo $SUPABASE_DATABASE_URL | sed -E 's/postgresql:\/\/[^:]+:([^@]+)@.*/\1/')

# Validate extracted values
if [[ -z "$DB_HOST" || -z "$DB_PORT" || -z "$DB_NAME" || -z "$DB_USER" ]]; then
    echo -e "${RED}Error: Could not parse DATABASE_URL components${NC}"
    echo "URL format should be: postgresql://user:pass@host:port/database"
    exit 1
fi

echo -e "${RED}⚠️  WARNING: This will permanently delete ALL data from the Cinegraph database!${NC}"
echo -e "${YELLOW}This includes movies, people, collaborations, festivals, and all other data.${NC}"
echo ""
echo "Database: $DB_NAME on $DB_HOST:$DB_PORT"
echo ""
echo "Are you sure you want to continue? This action cannot be undone."
echo "Type 'yes' to proceed or anything else to cancel:"
read -r confirmation

if [[ "$confirmation" != "yes" ]]; then
    echo -e "${GREEN}Cancelled. Database was not modified.${NC}"
    exit 0
fi

echo ""

# First, try to terminate any active connections (this might fail but that's OK)
echo "Attempting to close active connections..."
PGPASSWORD=$DB_PASS psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "
SELECT pg_terminate_backend(pid) 
FROM pg_stat_activity 
WHERE datname = '$DB_NAME' 
  AND pid <> pg_backend_pid()
  AND state = 'idle';" 2>/dev/null || true

# Get all tables except schema_migrations
echo "Finding all tables to clear..."
TABLES=$(PGPASSWORD=$DB_PASS psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "
SELECT string_agg(tablename, ', ')
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename != 'schema_migrations';")

if [[ -z "$TABLES" || "$TABLES" == " " ]]; then
    echo -e "${YELLOW}No tables found to clear (database might already be empty)${NC}"
    exit 0
fi

echo "Tables to clear: $TABLES"
echo ""

# Truncate all tables (tables already validated from system catalog)
echo "Clearing all data..."
# Since $TABLES comes from pg_tables, we know they're valid table names
# No additional quoting needed as PostgreSQL already ensures they're safe
PGPASSWORD=$DB_PASS psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "TRUNCATE TABLE $TABLES CASCADE;" 2>&1 | grep -v "WARNING"

# Verify the data was cleared
echo ""
echo "Verifying data was cleared..."
MOVIE_COUNT=$(PGPASSWORD=$DB_PASS psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "SELECT COUNT(*) FROM movies;" 2>/dev/null || echo "0")
PEOPLE_COUNT=$(PGPASSWORD=$DB_PASS psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "SELECT COUNT(*) FROM people;" 2>/dev/null || echo "0")
OSCAR_COUNT=$(PGPASSWORD=$DB_PASS psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "SELECT COUNT(*) FROM oscar_ceremonies;" 2>/dev/null || echo "0")

echo "Movie count: $MOVIE_COUNT"
echo "People count: $PEOPLE_COUNT"
echo "Oscar ceremonies count: $OSCAR_COUNT"

if [[ "$MOVIE_COUNT" -eq 0 ]] && [[ "$PEOPLE_COUNT" -eq 0 ]] && [[ "$OSCAR_COUNT" -eq 0 ]]; then
    echo ""
    echo -e "${GREEN}✅ Database cleared successfully!${NC}"
    
    # Ask if user wants to reseed default movie lists
    echo ""
    echo "Would you like to reseed the default movie lists? (y/n)"
    read -r reseed_response
    
    if [[ "$reseed_response" == "y" ]] || [[ "$reseed_response" == "Y" ]]; then
        echo ""
        echo -e "${YELLOW}🌱 Reseeding default movie lists...${NC}"
        mix run priv/repo/seeds.exs
    fi
    
    echo ""
    echo "You can now run imports with a clean database:"
    echo "  - Start the server: ./start.sh"
    echo "  - Visit: http://localhost:4001/imports"
    echo "  - Or use: ./scripts/import_with_env.sh --pages 10"
else
    echo ""
    echo -e "${RED}❌ Warning: Some data might still remain in the database${NC}"
fi