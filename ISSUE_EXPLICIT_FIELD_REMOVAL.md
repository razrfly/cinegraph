# Explicit Database Reorganization: Field Removal and Data Migration Plan

## Fields to Remove from Movies Table

### Category 1: Ratings & Popularity Metrics
**Fields Being Removed:**
- `vote_average` (float) - TMDb average rating
- `vote_count` (integer) - TMDb number of votes  
- `popularity` (float) - TMDb popularity score

**Where They Move:** → `external_metrics` table

### Category 2: Financial Data
**Fields Being Removed:**
- `budget` (integer) - Production budget
- `revenue` (integer) - Total revenue
- `box_office_domestic` (integer) - Domestic box office

**Where They Move:** → `external_metrics` table

### Category 3: Awards & Recognition
**Fields Being Removed:**
- `awards_text` (string) - OMDb awards text
- `awards` (map) - Parsed awards data

**Where They Move:** → `external_metrics` table

## Fields That STAY in Movies Table

### Core Identity (Never Changes)
- `tmdb_id` - The Movie Database ID
- `imdb_id` - Internet Movie Database ID

### Core Facts (Rarely Change)
- `title` - Movie title
- `original_title` - Original language title
- `release_date` - Official release date
- `runtime` - Duration in minutes
- `overview` - Plot summary
- `tagline` - Marketing tagline
- `original_language` - Original language code
- `status` - Release status
- `adult` - Adult content flag
- `homepage` - Official website
- `origin_country` - Countries of origin

### Media & Collections
- `poster_path` - Poster image path
- `backdrop_path` - Backdrop image path
- `collection_id` - Franchise/series ID

### System Fields
- `tmdb_data` - Raw TMDb response (reference)
- `omdb_data` - Raw OMDb response (reference)
- `import_status` - Import tracking
- `canonical_sources` - List membership tracking
- `timestamps` - Created/updated timestamps

## Data Categories and Migration Examples

### 1. RATINGS (User/Critic Scores)

**Current State (Scattered across tables):**
```elixir
# In movies table:
vote_average: 8.5      # TMDb rating
vote_count: 15234      # TMDb votes

# In external_ratings table (if used):
rating_type: "user", value: 8.5  # Unclear source

# In omdb_data JSON:
"imdbRating" => "8.5"
"imdbVotes" => "1,234,567"
"Metascore" => "74"
"Ratings" => [
  %{"Source" => "Internet Movie Database", "Value" => "8.5/10"},
  %{"Source" => "Rotten Tomatoes", "Value" => "87%"},
  %{"Source" => "Metacritic", "Value" => "74/100"}
]
```

**New Structure (Unified in external_metrics):**
```elixir
# All ratings in external_metrics table:
[
  %{
    movie_id: 123,
    source: "tmdb",
    metric_type: "rating_average",
    value: 8.5,
    metadata: %{"scale" => "1-10"},
    fetched_at: ~U[2024-08-11 10:00:00Z]
  },
  %{
    movie_id: 123,
    source: "tmdb",
    metric_type: "rating_votes",
    value: 15234,
    fetched_at: ~U[2024-08-11 10:00:00Z]
  },
  %{
    movie_id: 123,
    source: "imdb",
    metric_type: "rating_average",
    value: 8.5,
    metadata: %{"scale" => "1-10"},
    fetched_at: ~U[2024-08-11 10:00:00Z]
  },
  %{
    movie_id: 123,
    source: "imdb",
    metric_type: "rating_votes",
    value: 1234567,
    fetched_at: ~U[2024-08-11 10:00:00Z]
  },
  %{
    movie_id: 123,
    source: "rotten_tomatoes",
    metric_type: "tomatometer",
    value: 87,
    metadata: %{"scale" => "0-100", "type" => "critics"},
    fetched_at: ~U[2024-08-11 10:00:00Z]
  },
  %{
    movie_id: 123,
    source: "metacritic",
    metric_type: "metascore",
    value: 74,
    metadata: %{"scale" => "0-100", "type" => "critics"},
    fetched_at: ~U[2024-08-11 10:00:00Z]
  }
]
```

### 2. FINANCIAL METRICS (Box Office, Budget)

**Current State:**
```elixir
# In movies table:
budget: 200000000           # From TMDb
revenue: 1074000000         # From TMDb
box_office_domestic: 381409310  # From OMDb

# In omdb_data JSON:
"BoxOffice" => "$381,409,310"
```

**New Structure:**
```elixir
[
  %{
    movie_id: 123,
    source: "tmdb",
    metric_type: "budget",
    value: 200000000,
    metadata: %{
      "currency" => "USD",
      "status" => "confirmed"  # or "estimated"
    },
    fetched_at: ~U[2024-08-11 10:00:00Z]
  },
  %{
    movie_id: 123,
    source: "tmdb",
    metric_type: "revenue_worldwide",
    value: 1074000000,
    metadata: %{
      "currency" => "USD",
      "includes" => ["domestic", "international"]
    },
    fetched_at: ~U[2024-08-11 10:00:00Z]
  },
  %{
    movie_id: 123,
    source: "omdb",
    metric_type: "revenue_domestic",
    value: 381409310,
    metadata: %{
      "currency" => "USD",
      "territory" => "USA/Canada"
    },
    fetched_at: ~U[2024-08-11 10:00:00Z]
  },
  %{
    movie_id: 123,
    source: "the_numbers",  # Future source
    metric_type: "revenue_opening_weekend",
    value: 132800000,
    metadata: %{
      "currency" => "USD",
      "territory" => "USA/Canada",
      "days" => 3
    },
    fetched_at: ~U[2024-08-11 10:00:00Z]
  }
]
```

### 3. POPULARITY & ENGAGEMENT METRICS

**Current State:**
```elixir
# In movies table:
popularity: 45.234  # TMDb popularity score

# Not currently stored but available:
# TMDb trending rank
# IMDb popularity rank
# Social media mentions
```

**New Structure:**
```elixir
[
  %{
    movie_id: 123,
    source: "tmdb",
    metric_type: "popularity_score",
    value: 45.234,
    metadata: %{
      "algorithm_version" => "v3",
      "factors" => ["views", "votes", "watchlist_adds"]
    },
    fetched_at: ~U[2024-08-11 10:00:00Z]
  },
  %{
    movie_id: 123,
    source: "tmdb",
    metric_type: "trending_rank",
    value: 3,
    metadata: %{
      "period" => "day",
      "region" => "US"
    },
    fetched_at: ~U[2024-08-11 10:00:00Z]
  },
  %{
    movie_id: 123,
    source: "imdb",
    metric_type: "popularity_rank",
    value: 15,
    metadata: %{"period" => "week"},
    fetched_at: ~U[2024-08-11 10:00:00Z]
  }
]
```

### 4. AWARDS & RECOGNITION

**Current State:**
```elixir
# In movies table:
awards_text: "Won 3 Oscars. 53 wins & 104 nominations total"
awards: %{
  "oscars" => %{"wins" => 3, "nominations" => 9},
  "total" => %{"wins" => 53, "nominations" => 104}
}

# In omdb_data JSON:
"Awards" => "Won 3 Oscars. 53 wins & 104 nominations total"
```

**New Structure:**
```elixir
[
  %{
    movie_id: 123,
    source: "omdb",
    metric_type: "awards_summary",
    text_value: "Won 3 Oscars. 53 wins & 104 nominations total",
    metadata: %{
      "oscar_wins" => 3,
      "oscar_nominations" => 9,
      "total_wins" => 53,
      "total_nominations" => 104
    },
    fetched_at: ~U[2024-08-11 10:00:00Z]
  },
  %{
    movie_id: 123,
    source: "omdb",
    metric_type: "oscar_wins",
    value: 3,
    fetched_at: ~U[2024-08-11 10:00:00Z]
  },
  %{
    movie_id: 123,
    source: "omdb",
    metric_type: "total_awards",
    value: 53,
    metadata: %{"type" => "wins"},
    fetched_at: ~U[2024-08-11 10:00:00Z]
  }
]
```

### 5. RECOMMENDATIONS (Different from Ratings!)

**Note:** Recommendations are NOT ratings. They are suggested similar/related movies.

**Current State (external_recommendations table):**
```elixir
%{
  source_movie_id: 123,
  recommended_movie_id: 456,
  source_id: 1,  # References external_sources table
  recommendation_type: "similar",
  score: 0.95
}
```

**New Structure (simplified movie_recommendations):**
```elixir
[
  %{
    source_movie_id: 123,
    recommended_movie_id: 456,
    source: "tmdb",
    type: "similar",
    rank: 1,  # Position in recommendation list
    score: 0.95,  # Similarity score
    fetched_at: ~U[2024-08-11 10:00:00Z]
  },
  %{
    source_movie_id: 123,
    recommended_movie_id: 789,
    source: "tmdb",
    type: "recommended",  # Different algorithm than "similar"
    rank: 1,
    score: 0.89,
    fetched_at: ~U[2024-08-11 10:00:00Z]
  }
]
```

## Complete Schema Comparison

### BEFORE: 4 Tables with Overlap
```
movies (25+ fields including volatile data)
├── vote_average, vote_count, popularity (TMDb)
├── budget, revenue (TMDb)
├── box_office_domestic, awards_text (OMDb)
└── tmdb_data, omdb_data (raw JSON)

external_sources (lookup table)
├── name, source_type, base_url
└── weight_factor, config

external_ratings (limited flexibility)
├── source_id → external_sources
├── rating_type (limited enum)
├── value, scale_min, scale_max
└── metadata

external_recommendations
├── source_id → external_sources
├── recommendation_type
└── score, metadata
```

### AFTER: 2 Clean Tables
```
movies (16 core fields only)
├── Identity: tmdb_id, imdb_id
├── Facts: title, release_date, runtime, overview...
├── Media: poster_path, backdrop_path
└── System: tmdb_data, omdb_data, canonical_sources

external_metrics (all volatile/subjective data)
├── movie_id → movies
├── source: "tmdb", "omdb", "metacritic", etc.
├── metric_type: flexible string
├── value: numeric value
├── text_value: text data (awards, etc.)
├── metadata: additional context
└── fetched_at, valid_until

movie_recommendations (simplified)
├── source_movie_id → movies
├── recommended_movie_id → movies
├── source, type, rank, score
└── fetched_at
```

## Migration SQL Examples

```sql
-- Step 1: Create external_metrics table
CREATE TABLE external_metrics (
  id SERIAL PRIMARY KEY,
  movie_id INTEGER NOT NULL REFERENCES movies(id) ON DELETE CASCADE,
  source VARCHAR(50) NOT NULL,
  metric_type VARCHAR(100) NOT NULL,
  value DOUBLE PRECISION,
  text_value TEXT,
  metadata JSONB DEFAULT '{}',
  fetched_at TIMESTAMP WITH TIME ZONE NOT NULL,
  valid_until TIMESTAMP WITH TIME ZONE,
  inserted_at TIMESTAMP WITH TIME ZONE NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL
);

-- Step 2: Migrate TMDb ratings
INSERT INTO external_metrics (movie_id, source, metric_type, value, fetched_at, inserted_at, updated_at)
SELECT id, 'tmdb', 'rating_average', vote_average, NOW(), NOW(), NOW()
FROM movies WHERE vote_average IS NOT NULL;

INSERT INTO external_metrics (movie_id, source, metric_type, value, fetched_at, inserted_at, updated_at)
SELECT id, 'tmdb', 'rating_votes', vote_count, NOW(), NOW(), NOW()
FROM movies WHERE vote_count IS NOT NULL;

-- Step 3: Migrate financial data
INSERT INTO external_metrics (movie_id, source, metric_type, value, metadata, fetched_at, inserted_at, updated_at)
SELECT id, 'tmdb', 'budget', budget, '{"currency": "USD"}'::jsonb, NOW(), NOW(), NOW()
FROM movies WHERE budget IS NOT NULL AND budget > 0;

-- Step 4: Migrate OMDb data from JSON
INSERT INTO external_metrics (movie_id, source, metric_type, value, metadata, fetched_at, inserted_at, updated_at)
SELECT 
  id, 
  'omdb', 
  'revenue_domestic',
  CAST(REGEXP_REPLACE(omdb_data->>'BoxOffice', '[^0-9]', '', 'g') AS BIGINT),
  '{"currency": "USD", "territory": "USA/Canada"}'::jsonb,
  NOW(), NOW(), NOW()
FROM movies 
WHERE omdb_data->>'BoxOffice' IS NOT NULL;

-- Step 5: Create backward-compatible view
CREATE VIEW movies_with_metrics AS
SELECT 
  m.*,
  -- Ratings
  tmdb_rating.value as vote_average,
  tmdb_votes.value as vote_count,
  tmdb_pop.value as popularity,
  -- Financials
  budget.value as budget,
  revenue.value as revenue,
  box_office.value as box_office_domestic,
  -- Awards
  awards.text_value as awards_text
FROM movies m
LEFT JOIN LATERAL (
  SELECT value FROM external_metrics 
  WHERE movie_id = m.id AND source = 'tmdb' AND metric_type = 'rating_average'
  ORDER BY fetched_at DESC LIMIT 1
) tmdb_rating ON true
LEFT JOIN LATERAL (
  SELECT value FROM external_metrics 
  WHERE movie_id = m.id AND source = 'tmdb' AND metric_type = 'rating_votes'
  ORDER BY fetched_at DESC LIMIT 1
) tmdb_votes ON true
-- ... etc for other fields
```

## Querying Examples

### Get Movie with Latest Metrics
```elixir
def get_movie_with_current_metrics(movie_id) do
  movie = Repo.get!(Movie, movie_id)
  
  # Get latest metrics grouped by source
  metrics_query = from m in ExternalMetric,
    where: m.movie_id == ^movie_id,
    distinct: [m.source, m.metric_type],
    order_by: [desc: m.fetched_at]
    
  metrics = Repo.all(metrics_query)
  |> Enum.group_by(& &1.source)
  |> Enum.map(fn {source, metrics} ->
    {source, Enum.map(metrics, fn m -> 
      {m.metric_type, m.value || m.text_value}
    end) |> Enum.into(%{})}
  end)
  |> Enum.into(%{})
  
  %{
    movie: movie,
    metrics: %{
      tmdb: metrics["tmdb"] || %{},
      omdb: metrics["omdb"] || %{},
      metacritic: metrics["metacritic"] || %{}
    }
  }
end
```

### Compare Ratings Across Sources
```elixir
def compare_ratings(movie_id) do
  from(m in ExternalMetric,
    where: m.movie_id == ^movie_id,
    where: m.metric_type in ["rating_average", "metascore", "tomatometer"],
    select: %{
      source: m.source,
      rating: m.value,
      scale: fragment("?->>'scale'", m.metadata),
      fetched: m.fetched_at
    }
  )
  |> Repo.all()
end
```

### Track Popularity Over Time
```elixir
def popularity_trend(movie_id, days \\ 30) do
  from(m in ExternalMetric,
    where: m.movie_id == ^movie_id,
    where: m.metric_type == "popularity_score",
    where: m.fetched_at > ago(^days, "day"),
    order_by: [asc: m.fetched_at],
    select: %{date: m.fetched_at, popularity: m.value}
  )
  |> Repo.all()
end
```

## Benefits Summary

1. **Clear Separation**: Core facts vs. volatile metrics
2. **Source Attribution**: Every data point has clear provenance
3. **Historical Tracking**: Can see how metrics change over time
4. **Flexible Schema**: Add new metrics without migrations
5. **Better Performance**: Smaller movies table, focused indexes
6. **Easier Maintenance**: Clear data model, less confusion
7. **Powerful Analytics**: Compare sources, track trends, measure freshness

## Implementation Checklist

- [ ] Create `external_metrics` table
- [ ] Create data migration script
- [ ] Update import pipelines (TMDb, OMDb)
- [ ] Create backward-compatible views
- [ ] Update all queries to use new structure
- [ ] Test thoroughly with production data
- [ ] Remove deprecated fields from movies table
- [ ] Drop `external_sources` table (no longer needed)
- [ ] Update documentation