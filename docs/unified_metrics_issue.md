# Unified Metrics Registry System

## Problem Statement
Currently, different types of movie data (ratings, awards, box office, etc.) are stored in various formats and locations, making it difficult to:
- Normalize and compare different data sources
- Apply consistent weighting across metrics
- Add new data sources easily
- Build flexible search filters
- Understand data coverage and quality

## Solution: Unified Metrics Registry

### Core Concepts

1. **Metric Definition**: Abstract representation of any measurable movie attribute
2. **Source Reliability**: Quality/trust score for each data provider
3. **Normalization Rules**: How to convert raw values to 0-1 scale
4. **Weighting Profiles**: Configurable weight sets for different use cases
5. **Coverage Tracking**: Real-time visibility into data completeness

## Complete Data Source Inventory

### 1. User & Critic Ratings (Scores)
| Source | Metric Type | Raw Scale | Current Storage |
|--------|------------|-----------|-----------------|
| TMDb | rating_average | 0-10 | external_metrics |
| TMDb | vote_count | 0-∞ | external_metrics |
| IMDb | rating_average | 0-10 | external_metrics |
| IMDb | vote_count | 0-∞ | external_metrics |
| Metacritic | metascore | 0-100 | external_metrics |
| Rotten Tomatoes | tomatometer | 0-100% | external_metrics |
| Rotten Tomatoes | audience_score | 0-100% | external_metrics |

### 2. Popularity & Engagement
| Source | Metric Type | Raw Scale | Current Storage |
|--------|------------|-----------|-----------------|
| TMDb | popularity_score | 0-∞ | external_metrics |
| TMDb | trending_rank | 1-∞ | not stored |
| IMDb | popularity_rank | 1-∞ | not stored |

### 3. Financial Performance
| Source | Metric Type | Raw Scale | Current Storage |
|--------|------------|-----------|-----------------|
| TMDb | budget | $0-∞ | movies.tmdb_data |
| TMDb | revenue | $0-∞ | movies.tmdb_data |
| OMDb | box_office | $0-∞ | external_metrics |
| Box Office Mojo | domestic_gross | $0-∞ | not integrated |
| Box Office Mojo | worldwide_gross | $0-∞ | not integrated |

### 4. Awards & Recognition
| Source | Metric Type | Raw Scale | Current Storage |
|--------|------------|-----------|-----------------|
| Oscars | nominations | 0-∞ | festival_nominations |
| Oscars | wins | 0-∞ | festival_nominations |
| Cannes | selections | boolean | festival_nominations |
| Cannes | awards | categorical | festival_nominations |
| Venice | selections | boolean | festival_nominations |
| Venice | awards | categorical | festival_nominations |
| Berlin | selections | boolean | festival_nominations |
| Berlin | awards | categorical | festival_nominations |
| Sundance | selections | boolean | festival_nominations |
| Sundance | awards | categorical | festival_nominations |

### 5. Cultural Impact & Canon
| Source | Metric Type | Raw Scale | Current Storage |
|--------|------------|-----------|-----------------|
| AFI Top 100 | list_rank | 1-100 | movies.canonical_sources |
| BFI Top 100 | list_rank | 1-100 | movies.canonical_sources |
| Sight & Sound | list_rank | 1-250 | movies.canonical_sources |
| Criterion Collection | inclusion | boolean | movies.canonical_sources |
| 1001 Movies | inclusion | boolean | movies.canonical_sources |
| National Film Registry | inclusion | boolean | movies.canonical_sources |

### 6. Content & Classification (Future)
| Source | Metric Type | Raw Scale | Current Storage |
|--------|------------|-----------|-----------------|
| MPAA | rating | categorical | movies.certification |
| Genre Score | drama_score | 0-1 | not implemented |
| Genre Score | action_score | 0-1 | not implemented |
| Runtime | duration | 0-∞ min | movies.runtime |

## Database Schema

```sql
-- Core registry table for metric definitions
CREATE TABLE metric_definitions (
  id SERIAL PRIMARY KEY,
  code VARCHAR(50) UNIQUE NOT NULL, -- e.g., 'tmdb_rating', 'oscar_wins'
  name VARCHAR(100) NOT NULL,
  category VARCHAR(50) NOT NULL, -- 'rating', 'award', 'financial', 'cultural', 'popularity'
  source VARCHAR(50) NOT NULL, -- 'tmdb', 'imdb', 'metacritic', 'oscars', etc.
  data_type VARCHAR(20) NOT NULL, -- 'numeric', 'boolean', 'categorical', 'rank'
  
  -- Raw value information
  raw_scale_min FLOAT,
  raw_scale_max FLOAT,
  raw_unit VARCHAR(20), -- '$', '%', 'count', 'rank', null
  
  -- Normalization configuration
  normalization_type VARCHAR(20), -- 'linear', 'logarithmic', 'sigmoid', 'custom'
  normalization_params JSONB, -- {"threshold": 100, "curve": 2.5}
  normalized_weight FLOAT DEFAULT 1.0, -- Importance within category
  
  -- Quality and reliability
  source_reliability FLOAT DEFAULT 0.8, -- 0-1 trust score
  freshness_days INTEGER, -- How often data should be refreshed
  coverage_threshold FLOAT DEFAULT 0.7, -- Min % of movies that should have this
  
  -- Metadata
  description TEXT,
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Weight profiles for different use cases
CREATE TABLE weight_profiles (
  id SERIAL PRIMARY KEY,
  name VARCHAR(50) UNIQUE NOT NULL, -- 'balanced', 'crowd_pleaser', 'critics_choice'
  description TEXT,
  is_default BOOLEAN DEFAULT false,
  is_system BOOLEAN DEFAULT true, -- System profiles can't be edited
  user_id INTEGER REFERENCES users(id), -- For custom user profiles
  
  -- Category weights (sum to 1.0)
  rating_weight FLOAT DEFAULT 0.25,
  award_weight FLOAT DEFAULT 0.25,
  financial_weight FLOAT DEFAULT 0.25,
  cultural_weight FLOAT DEFAULT 0.25,
  popularity_weight FLOAT DEFAULT 0.0,
  
  -- Additional configuration
  config JSONB DEFAULT '{}',
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Detailed weights for specific metrics within profiles
CREATE TABLE profile_metric_weights (
  id SERIAL PRIMARY KEY,
  profile_id INTEGER REFERENCES weight_profiles(id) ON DELETE CASCADE,
  metric_code VARCHAR(50) REFERENCES metric_definitions(code),
  weight FLOAT DEFAULT 1.0, -- Weight within its category
  enabled BOOLEAN DEFAULT true,
  UNIQUE(profile_id, metric_code)
);

-- Track data coverage statistics
CREATE TABLE metric_coverage_stats (
  id SERIAL PRIMARY KEY,
  metric_code VARCHAR(50) REFERENCES metric_definitions(code),
  total_movies INTEGER NOT NULL,
  movies_with_data INTEGER NOT NULL,
  coverage_percentage FLOAT NOT NULL,
  avg_value FLOAT,
  min_value FLOAT,
  max_value FLOAT,
  median_value FLOAT,
  last_calculated TIMESTAMP NOT NULL DEFAULT NOW(),
  UNIQUE(metric_code, last_calculated)
);

-- Indexes for performance
CREATE INDEX idx_metric_definitions_category ON metric_definitions(category);
CREATE INDEX idx_metric_definitions_source ON metric_definitions(source);
CREATE INDEX idx_weight_profiles_user ON weight_profiles(user_id);
CREATE INDEX idx_coverage_stats_metric ON metric_coverage_stats(metric_code);
CREATE INDEX idx_coverage_stats_date ON metric_coverage_stats(last_calculated);
```

## Normalization Strategies

### 1. Linear Normalization (Most Common)
```elixir
# For bounded scales (ratings, percentages)
normalized = (value - min) / (max - min)

# Examples:
# IMDb 7.5/10 → 0.75
# Metacritic 85/100 → 0.85
# RT Tomatometer 92% → 0.92
```

### 2. Logarithmic Normalization (For Unbounded Data)
```elixir
# For counts, money, popularity
normalized = log(value + 1) / log(threshold + 1)

# Examples:
# Vote count: log(50000 + 1) / log(1000000 + 1) → 0.78
# Box office: log(100M + 1) / log(1B + 1) → 0.67
```

### 3. Sigmoid Normalization (For Rankings)
```elixir
# For list rankings where lower is better
normalized = 1 / (1 + exp(-k * (midpoint - rank)))

# Examples:
# AFI Top 100 rank 25 → 0.75
# Sight & Sound rank 150/250 → 0.40
```

### 4. Boolean/Categorical Normalization
```elixir
# For presence/absence or award wins
normalized = case value do
  true -> 1.0  # Has award/inclusion
  false -> 0.0 # Doesn't have
  "gold" -> 1.0 # Top award
  "silver" -> 0.7 # Second tier
  "bronze" -> 0.4 # Third tier
end
```

## Use Cases

### 1. General Search: "Highly Rated Movies"
```elixir
# Combines all rating sources with normalization
search_params = %{
  category: "rating",
  min_normalized_value: 0.8,
  sources: ["tmdb", "imdb", "metacritic", "rotten_tomatoes"]
}

# SQL generated:
SELECT DISTINCT m.* FROM movies m
JOIN external_metrics em ON m.id = em.movie_id
JOIN metric_definitions md ON md.source = em.source 
  AND md.category = 'rating'
WHERE 
  normalize_value(em.value, md.*) >= 0.8
  AND md.code IN ('tmdb_rating', 'imdb_rating', 'metacritic_score', 'rt_tomatometer')
```

### 2. Specific Search: "Metacritic Score > 80"
```elixir
# Direct metric query without normalization
search_params = %{
  metric_code: "metacritic_score",
  min_raw_value: 80
}

# SQL generated:
SELECT m.* FROM movies m
JOIN external_metrics em ON m.id = em.movie_id
WHERE 
  em.source = 'metacritic' 
  AND em.metric_type = 'metascore'
  AND em.value >= 80
```

### 3. Combined Search: "Award Winners with High Ratings"
```elixir
# Multi-category search
search_params = %{
  filters: [
    {category: "award", min_normalized: 0.5}, # Has some awards
    {category: "rating", min_normalized: 0.7}  # Well rated
  ],
  weight_profile: "critics_choice"
}
```

### 4. Discovery: "Hidden Gems"
```elixir
# Low popularity but high quality
search_params = %{
  filters: [
    {metric_code: "tmdb_popularity", max_normalized: 0.3},
    {category: "rating", min_normalized: 0.8},
    {category: "cultural", min_normalized: 0.6}
  ]
}
```

### 5. Financial Success Stories
```elixir
# High ROI movies
search_params = %{
  filters: [
    {metric_code: "budget", max_raw: 10_000_000},
    {metric_code: "worldwide_gross", min_raw: 100_000_000}
  ]
}
```

## Implementation Plan

### Phase 1: Foundation (Week 1)
- [ ] Create migration for new tables
- [ ] Build `Cinegraph.Metrics.Registry` context
- [ ] Implement `MetricDefinition` schema and CRUD
- [ ] Create seed data for all current metrics
- [ ] Build normalization functions

### Phase 2: Data Migration (Week 2)
- [ ] Migrate existing scoring logic to use registry
- [ ] Update external_metrics references
- [ ] Create coverage calculation job
- [ ] Build weight profile management

### Phase 3: Integration (Week 3)
- [ ] Update discovery scoring to use registry
- [ ] Create search filter builders
- [ ] Add LiveView dashboard for metrics
- [ ] Implement real-time weight adjustment
- [ ] Create API for metric queries

### Phase 4: Enhancement (Week 4)
- [ ] Add custom user weight profiles
- [ ] Build metric combination rules
- [ ] Create data quality monitoring
- [ ] Add new data source onboarding flow
- [ ] Performance optimization

## Benefits

1. **Single Source of Truth**: All metric definitions in one place
2. **Flexibility**: Easy to add new sources or adjust weights
3. **Consistency**: Normalized values enable fair comparisons
4. **Transparency**: Clear visibility into data coverage and quality
5. **Extensibility**: Simple to add new data sources
6. **Performance**: Cached calculations and indexed queries
7. **User Control**: Custom weight profiles for personalization

## Success Metrics

- All existing scoring uses unified registry
- 90%+ of movies have normalized metrics
- Dashboard shows real-time coverage stats
- New data source can be added in < 1 hour
- Search queries support all metric types
- Weight adjustments reflect immediately

## Future Extensions

- Machine learning for optimal weight discovery
- Time-based metrics (trending over time)
- Geographic metrics (regional popularity)
- Social metrics (Twitter mentions, Reddit discussions)
- Streaming metrics (Netflix rankings, views)
- Critical consensus (aggregated review scores)