# Canonical Import Fix Summary

## Problem
Movies appearing in multiple canonical lists were only getting tagged with ONE list because:
- Oban's unique constraint prevented multiple jobs for the same movie
- Each list tried to create a separate job, but only the first succeeded

## Solution Implemented

### 1. Updated TMDbDetailsWorker Unique Constraint
Changed from:
```elixir
unique: [fields: [:args], keys: [:tmdb_id, :imdb_id], period: 300]
```

To:
```elixir
unique: [fields: [:args], keys: [:tmdb_id, :imdb_id, :source_key], period: 300]
```

This allows one job per movie per canonical list.

### 2. Updated CanonicalPageWorker
- Removed direct movie updates when movie exists
- Now always creates a TMDbDetailsWorker job (for both new and existing movies)
- Added `source_key` to job args for the unique constraint
- This ensures all canonical sources go through the same update path

### 3. Preserved mark_movie_canonical Logic
- Already uses `Map.put` which replaces the value for a specific key
- When re-running imports, it will replace the data for that list only
- Other canonical sources remain untouched

## How It Works Now

1. **First Import**: List A imports movie → creates job with source_key "list_a" → movie gets `{"list_a": {...}}`
2. **Second Import**: List B imports same movie → creates job with source_key "list_b" → movie gets `{"list_a": {...}, "list_b": {...}}`
3. **Re-run Import**: List A imports again → creates job with source_key "list_a" → replaces only "list_a" data

## Benefits
- Movies can belong to multiple canonical lists
- Re-running imports updates only that list's data
- No more silent job drops
- Consistent handling for new and existing movies