# OMDb API vs Current Schema Audit

## Executive Summary

**Good news**: Your current schema can handle OMDb data with minimal changes. The `external_ratings` and `external_sources` tables are perfectly designed for this integration.

## Current Schema Analysis

### ✅ Tables That Are Perfect for OMDb

#### 1. `external_sources` table
- Already exists and matches our needs exactly
- Can store OMDb as a source with configuration
- Has `source_type`, `base_url`, `api_version` fields ready

#### 2. `external_ratings` table
- Designed exactly for this use case
- Has `rating_type` field that supports: "user", "critic", "algorithm"
- Has `metadata` JSONB field for extra data (consensus text, fresh/rotten counts)
- Has `scale_min`/`scale_max` for different rating scales
- Unique constraint on `[movie_id, source_id, rating_type]` prevents duplicates

### 🔄 Tables That Need Minor Updates

#### 1. `cultural_authorities` table
- Can store award bodies (Academy Awards, etc.)
- `data_source` field already includes "omdb" as valid option
- Use for tracking where award data comes from

#### 2. `movie_list_items` table
- Can store parsed award wins/nominations
- Has `award_category` and `award_result` fields
- Link movies to award lists via `curated_lists`

### ❌ Tables That Are Likely Unused/Removable

Based on your codebase scan, these tables have schemas but no apparent usage:
- `external_recommendations` - No OMDb equivalent
- `external_trending` - No OMDb equivalent
- `user_lists` - For crowdsourced lists (not from OMDb)
- `movie_user_list_appearances` - Aggregates user lists
- `movie_data_changes` - For tracking changes over time

## OMDb Data Mapping Strategy

### 1. Ratings Data → `external_ratings`

```elixir
# Create OMDb source once
omdb_source = %ExternalSources.Source{
  name: "OMDb",
  source_type: "api",
  base_url: "http://www.omdbapi.com",
  api_version: "1",
  config: %{
    "api_key" => System.get_env("OMDB_API_KEY"),
    "tier" => "free"  # or "patron"
  }
}

# For each movie's ratings
ratings = [
  %{
    movie_id: movie.id,
    source_id: omdb_source.id,
    rating_type: "critic",  # For Rotten Tomatoes critics
    value: 87.0,
    scale_max: 100.0,
    metadata: %{
      "source_name" => "Rotten Tomatoes",
      "consensus" => "Stanley Kubrick's brilliant Cold War satire...",
      "fresh_count" => 67,
      "rotten_count" => 1,
      "image" => "certified"
    }
  },
  %{
    movie_id: movie.id,
    source_id: omdb_source.id,
    rating_type: "user",  # For Rotten Tomatoes audience
    value: 94.0,
    scale_max: 100.0,
    metadata: %{
      "source_name" => "Rotten Tomatoes Audience",
      "review_count" => 170883
    }
  },
  %{
    movie_id: movie.id,
    source_id: omdb_source.id,
    rating_type: "critic",  # For Metacritic
    value: 74.0,
    scale_max: 100.0,
    metadata: %{"source_name" => "Metacritic"}
  }
]
```

### 2. Awards Data → Parse and Store

```elixir
# Option A: Simple - Store in movie metadata
# Just add to the movies table external_ids field:
movie.external_ids["omdb_awards"] = "Won 4 Oscars. 159 wins & 220 nominations total"

# Option B: Structured - Parse and store in cultural tables
# 1. Create Academy Awards authority if not exists
authority = %Cultural.Authority{
  name: "Academy Awards",
  authority_type: "award",
  data_source: "omdb"
}

# 2. Create Oscar Winners list
list = %Cultural.CuratedList{
  authority_id: authority.id,
  name: "Oscar Winners",
  list_type: "award"
}

# 3. Link movie if it won
if movie_won_oscar?(awards_text) do
  %Cultural.MovieListItem{
    movie_id: movie.id,
    list_id: list.id,
    award_result: "winner",
    notes: awards_text  # Store full text
  }
end
```

### 3. Box Office → Store in metadata

```elixir
# Add to external_ratings with special type
%{
  movie_id: movie.id,
  source_id: omdb_source.id,
  rating_type: "box_office",  # Add this to valid types
  value: 292_587_330.0,  # Parse from "$292,587,330"
  scale_max: 1_000_000_000.0,  # Billion for scale
  metadata: %{
    "currency" => "USD",
    "market" => "domestic",
    "raw_value" => "$292,587,330"
  }
}
```

## Recommended Schema Changes

### 1. Minimal Changes Needed

```elixir
# In ExternalSources.Rating changeset, update rating_type validation:
def changeset(rating, attrs) do
  rating
  |> cast(attrs, [...])
  |> validate_inclusion(:rating_type, [
    "user", "critic", "algorithm", "popularity", 
    "engagement", "list_appearances", 
    "box_office",  # ADD THIS
    "imdb_votes"   # ADD THIS
  ])
```

### 2. No New Tables Needed!

Your existing schema handles everything:
- `external_sources` → Store OMDb as a source
- `external_ratings` → Store all ratings, scores, and box office
- `metadata` JSONB → Store consensus text, vote counts, etc.
- `cultural_authorities` → Store award bodies
- `curated_lists` → Store award categories
- `movie_list_items` → Store award wins/nominations

### 3. Consider Removing Unused Tables

If confirmed unused after further investigation:
```sql
-- These seem unused based on codebase scan
DROP TABLE IF EXISTS external_recommendations CASCADE;
DROP TABLE IF EXISTS external_trending CASCADE;
DROP TABLE IF EXISTS movie_data_changes CASCADE;
```

## Implementation Path

1. **Use existing tables** - No migrations needed initially
2. **Add OMDb to external_sources** - One-time setup
3. **Store ratings in external_ratings** - Including RT consensus in metadata
4. **Parse awards minimally** - Start by storing text, parse later if needed
5. **Add validation for new rating_types** - "box_office", "imdb_votes"

## Why This Works

- Your schema was well-designed with JSONB `metadata` fields
- The `external_ratings` table is flexible enough for all OMDb data
- No need for OMDb-specific tables
- Can start integration immediately without migrations
- Awards parsing can be incremental (store text now, parse later)

## Next Steps

1. Create OMDb service module using existing schema
2. Test with a few movies to validate approach
3. Only add migrations if we discover missing needs
4. Consider removing truly unused tables after confirming