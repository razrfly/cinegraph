#!/bin/bash

echo "=== Testing Movie Sorting UI ==="
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
    
    # Check which option is selected
    selected=$(curl -s "http://localhost:4001/movies?sort=$sort_value&page=1" | grep "value=\"$sort_value\"" | grep -c "selected")
    
    if [ "$selected" -eq 1 ]; then
        echo "  ✅ Correct option is selected"
    else
        echo "  ❌ Selected attribute not found on correct option"
    fi
    
    # Check the sort parameter in the URL is preserved
    echo ""
done

echo "=== Test Complete ==="