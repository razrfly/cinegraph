#!/bin/bash

# Enable strict mode for better error handling
set -euo pipefail
IFS=$'\n\t'

# Make BASE_URL configurable via environment variable
BASE_URL="${BASE_URL:-http://localhost:4001}"

# Initialize failure counter
failures=0

echo "=== Testing Movie Sorting UI ==="
echo "Testing against: $BASE_URL"
echo ""

# Array of sort options
sort_options=(
    "release_date_desc:Release Date (Newest)"
    "release_date:Release Date (Oldest)"
    "title:Title (A-Z)"
    "title_desc:Title (Z-A)"
    "rating:Rating (Highest)"
    "popularity:Popularity"
)

# Test each sort option
for option in "${sort_options[@]}"; do
    IFS=':' read -r sort_value description <<< "$option"
    echo "Testing: $description (sort=$sort_value)"
    
    # Fetch the page and check HTTP status
    response=$(curl -fsS "$BASE_URL/movies?sort=$sort_value&page=1" 2>/dev/null) || {
        echo "  ❌ Failed to fetch page (HTTP error)"
        failures=$((failures + 1))
        echo ""
        continue
    }
    
    # Check which option is selected (order-insensitive regex)
    if echo "$response" | grep -Eq "<option[^>]*value=\"$sort_value\"[^>]*selected|<option[^>]*selected[^>]*value=\"$sort_value\""; then
        echo "  ✅ Correct option is selected"
    else
        echo "  ❌ Selected attribute not found on correct option"
        failures=$((failures + 1))
    fi
    
    # Check the sort parameter is preserved on pagination links
    pagination_links=$(echo "$response" | grep -Eo 'href="[^"]*page=[0-9]+[^"]*"' || true)
    
    if [ -z "$pagination_links" ]; then
        echo "  ⚠️  No pagination links found (may be single page)"
    else
        links_missing_sort=$(echo "$pagination_links" | grep -v "sort=" || true)
        
        if [ -z "$links_missing_sort" ]; then
            echo "  ✅ Pagination preserves sort parameter"
        else
            echo "  ❌ Some pagination links are missing the sort parameter:"
            echo "$links_missing_sort" | head -3 | sed 's/^/      /'
            failures=$((failures + 1))
        fi
    fi
    
    echo ""
done

# Exit with appropriate status
if [ "$failures" -gt 0 ]; then
    echo "=== Test Complete: ${failures} failure(s) ==="
    exit 1
fi

echo "=== Test Complete: All tests passed ✅ ==="
exit 0