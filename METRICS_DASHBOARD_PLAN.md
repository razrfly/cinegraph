# Unified Metrics Dashboard & Weighting Registry Plan

## Overview

Create a comprehensive dashboard to visualize all data sources, their coverage, and a centralized weighting registry that can be used across search, discovery, and backtesting systems.

## Current State Analysis

### Existing Weighting Systems

We have **multiple disconnected weighting systems**:

1. **Discovery Scoring System** (`discovery_scoring.ex`)
   - 4 dimensions: popular_opinion, critical_acclaim, industry_recognition, cultural_impact
   - 5 presets: balanced, crowd_pleaser, critics_choice, award_winner, cult_classic
   - Real-time adjustable via UI tuner

2. **External Metrics System** (`external_metrics` table)
   - 15+ metric types across 6 sources
   - No unified weighting, just raw storage
   - Sources: tmdb, omdb, imdb, metacritic, rotten_tomatoes, the_numbers

3. **CRI Scores** (`cri_scores` table)
   - 5 sub-scores plus overall score
   - Separate from discovery scoring
   - Not yet connected to UI

### Data Organization Challenges

1. **Scattered Data**:
   - Ratings in `external_metrics` (multiple sources)
   - Awards in `festival_nominations` table
   - Canonical lists in `movies.canonical_sources` JSONB
   - Box office in `external_metrics` (sparse coverage)

2. **Inconsistent Normalization**:
   - TMDb: 0-10 scale
   - Metacritic: 0-100 scale
   - Rotten Tomatoes: 0-100 percentage
   - Box office: Raw dollar amounts (not inflation-adjusted)

3. **No Central Registry**:
   - Weights hardcoded in multiple places
   - No single source of truth for metric importance
   - Difficult to A/B test different weight configurations

## Proposed Architecture

### 1. Centralized Weighting Registry

```elixir
defmodule Cinegraph.Metrics.Registry do
  @moduledoc """
  Central registry for all metric weights and normalization rules.
  Single source of truth for metric configuration.
  """

  @registry %{
    # Data Sources with coverage tracking
    sources: %{
      tmdb: %{
        name: "The Movie Database",
        metrics: [:rating_average, :rating_votes, :popularity_score, :budget, :revenue_worldwide],
        base_weight: 1.0,
        reliability: 0.95
      },
      imdb: %{
        name: "Internet Movie Database",
        metrics: [:rating_average, :rating_votes],
        base_weight: 1.2,  # Slightly higher weight due to larger user base
        reliability: 0.98
      },
      metacritic: %{
        name: "Metacritic",
        metrics: [:metascore],
        base_weight: 1.5,  # Higher weight for professional critics
        reliability: 0.90
      },
      rotten_tomatoes: %{
        name: "Rotten Tomatoes",
        metrics: [:tomatometer, :audience_score],
        base_weight: 1.3,
        reliability: 0.85
      },
      omdb: %{
        name: "Open Movie Database",
        metrics: [:awards_summary, :revenue_domestic],
        base_weight: 0.8,
        reliability: 0.75
      },
      festivals: %{
        name: "Festival Awards",
        metrics: [:nominations, :wins],
        base_weight: 2.0,  # High weight for industry recognition
        reliability: 0.95
      },
      canonical_lists: %{
        name: "Canonical Lists",
        metrics: [:list_memberships],
        base_weight: 1.8,  # High weight for cultural significance
        reliability: 1.0
      }
    },

    # Metric Types with normalization rules
    metrics: %{
      rating_average: %{
        category: :quality,
        normalization: :scale_10,
        aggregation: :weighted_mean,
        display_name: "Average Rating",
        importance: 0.8
      },
      rating_votes: %{
        category: :popularity,
        normalization: :logarithmic,
        aggregation: :sum,
        display_name: "Number of Votes",
        importance: 0.4
      },
      metascore: %{
        category: :critical,
        normalization: :scale_100,
        aggregation: :single,
        display_name: "Metascore",
        importance: 0.9
      },
      tomatometer: %{
        category: :critical,
        normalization: :percentage,
        aggregation: :single,
        display_name: "Critics Score",
        importance: 0.85
      },
      audience_score: %{
        category: :popular,
        normalization: :percentage,
        aggregation: :single,
        display_name: "Audience Score",
        importance: 0.6
      },
      budget: %{
        category: :financial,
        normalization: :inflation_adjusted,
        aggregation: :single,
        display_name: "Production Budget",
        importance: 0.3
      },
      revenue_worldwide: %{
        category: :financial,
        normalization: :inflation_adjusted,
        aggregation: :sum,
        display_name: "Box Office",
        importance: 0.5
      },
      festival_wins: %{
        category: :awards,
        normalization: :count,
        aggregation: :sum,
        display_name: "Festival Wins",
        importance: 1.0
      },
      festival_nominations: %{
        category: :awards,
        normalization: :count,
        aggregation: :sum,
        display_name: "Festival Nominations",
        importance: 0.5
      },
      canonical_lists: %{
        category: :cultural,
        normalization: :count,
        aggregation: :sum,
        display_name: "List Appearances",
        importance: 0.9
      }
    },

    # Category Weights (for high-level tuning)
    categories: %{
      quality: %{weight: 0.25, display_name: "Quality Ratings"},
      critical: %{weight: 0.25, display_name: "Critical Acclaim"},
      popular: %{weight: 0.20, display_name: "Popular Opinion"},
      financial: %{weight: 0.10, display_name: "Commercial Success"},
      awards: %{weight: 0.15, display_name: "Industry Recognition"},
      cultural: %{weight: 0.15, display_name: "Cultural Impact"}
    },

    # Normalization Functions
    normalizers: %{
      scale_10: &(&1 / 10.0),
      scale_100: &(&1 / 100.0),
      percentage: &(&1 / 100.0),
      logarithmic: &(:math.log10(&1 + 1) / 6),  # Assumes max ~1M votes
      count: &(min(&1 / 10, 1.0)),  # Cap at 10 for counts
      inflation_adjusted: :complex  # Requires year context
    }
  }

  def get_registry, do: @registry
  
  def get_weight(source, metric) do
    source_weight = @registry.sources[source][:base_weight] || 1.0
    metric_importance = @registry.metrics[metric][:importance] || 0.5
    source_weight * metric_importance
  end
  
  def normalize_value(metric, value, context \\ %{}) do
    normalizer = @registry.metrics[metric][:normalization]
    apply_normalizer(normalizer, value, context)
  end
end
```

### 2. Dashboard LiveView Components

```elixir
defmodule CinegraphWeb.Live.MetricsDashboard do
  use CinegraphWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign_data_sources()
     |> assign_coverage_stats()
     |> assign_weight_configuration()
     |> assign_canonical_lists()}
  end

  # Main sections of the dashboard:
  
  # 1. Data Sources Overview
  defp data_sources_section do
    [
      %{
        source: "TMDb",
        total_movies: 5506,
        metrics: ["Rating (7.2 avg)", "Votes (48k avg)", "Popularity", "Budget", "Revenue"],
        coverage: 99.7,
        last_updated: "2024-08-12"
      },
      %{
        source: "IMDb",
        total_movies: 3922,
        metrics: ["Rating (7.4 avg)", "Votes (52k avg)"],
        coverage: 71.0,
        last_updated: "2024-08-12"
      },
      %{
        source: "Metacritic",
        total_movies: 2016,
        metrics: ["Metascore (82.6 avg)"],
        coverage: 36.5,
        last_updated: "2024-08-12"
      },
      %{
        source: "Rotten Tomatoes",
        total_movies: 2831,
        metrics: ["Tomatometer (91% avg)", "Audience Score"],
        coverage: 51.3,
        last_updated: "2024-08-12"
      },
      %{
        source: "Festival Awards",
        nominations: 834,
        organizations: 7,
        coverage: 15.1,
        last_updated: "2024-08-11"
      }
    ]
  end

  # 2. Canonical Lists Section
  defp canonical_lists_section do
    [
      %{
        name: "1001 Movies You Must See",
        total: 1256,
        imported: true,
        coverage_of_db: 22.8,
        avg_rating: 7.4
      },
      %{
        name: "Criterion Collection",
        total: 1200,
        imported: false,
        coverage_of_db: 0,
        avg_rating: nil
      },
      %{
        name: "BFI Sight & Sound Top 100",
        total: 100,
        imported: false,
        coverage_of_db: 0,
        avg_rating: nil
      },
      %{
        name: "National Film Registry",
        total: 875,
        imported: false,
        coverage_of_db: 0,
        avg_rating: nil
      }
    ]
  end

  # 3. Weight Configuration Panel
  defp weight_configuration_panel do
    # Interactive sliders for each category
    # Save/Load preset configurations
    # A/B testing different weight sets
  end

  # 4. Coverage Heatmap
  defp coverage_heatmap do
    # Visual representation of data completeness
    # Color-coded by percentage coverage
    # Drill-down to specific gaps
  end
end
```

### 3. Database Schema Updates

```sql
-- Store weight configurations
CREATE TABLE weight_configurations (
  id BIGSERIAL PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  description TEXT,
  weights JSONB NOT NULL,
  is_active BOOLEAN DEFAULT false,
  created_by VARCHAR(100),
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

-- Track data source coverage over time
CREATE TABLE data_coverage_snapshots (
  id BIGSERIAL PRIMARY KEY,
  source VARCHAR(50) NOT NULL,
  metric_type VARCHAR(50) NOT NULL,
  total_movies INTEGER,
  movies_with_data INTEGER,
  coverage_percentage DECIMAL(5,2),
  avg_value DECIMAL(10,2),
  snapshot_date DATE DEFAULT CURRENT_DATE,
  created_at TIMESTAMP DEFAULT NOW()
);

-- Composite metrics for efficient querying
CREATE MATERIALIZED VIEW movie_composite_metrics AS
SELECT 
  m.id,
  m.title,
  m.release_date,
  
  -- Ratings composite
  jsonb_build_object(
    'tmdb', em_tmdb.value,
    'imdb', em_imdb.value,
    'metacritic', em_meta.value,
    'rotten_tomatoes', em_rt.value,
    'weighted_avg', (
      COALESCE(em_tmdb.value * 0.25, 0) +
      COALESCE(em_imdb.value * 0.3, 0) +
      COALESCE(em_meta.value / 10 * 0.25, 0) +
      COALESCE(em_rt.value / 10 * 0.2, 0)
    ) / NULLIF(
      (CASE WHEN em_tmdb.value IS NOT NULL THEN 0.25 ELSE 0 END +
       CASE WHEN em_imdb.value IS NOT NULL THEN 0.3 ELSE 0 END +
       CASE WHEN em_meta.value IS NOT NULL THEN 0.25 ELSE 0 END +
       CASE WHEN em_rt.value IS NOT NULL THEN 0.2 ELSE 0 END), 0)
  ) as ratings,
  
  -- Financial composite
  jsonb_build_object(
    'budget', em_budget.value,
    'revenue_worldwide', em_revenue.value,
    'revenue_domestic', em_domestic.value,
    'roi', CASE 
      WHEN em_budget.value > 0 
      THEN em_revenue.value / em_budget.value 
      ELSE NULL 
    END
  ) as financials,
  
  -- Awards composite
  jsonb_build_object(
    'festival_wins', COUNT(DISTINCT fn_win.id),
    'festival_nominations', COUNT(DISTINCT fn_nom.id),
    'oscar_wins', em_oscar_wins.value,
    'oscar_nominations', em_oscar_noms.value
  ) as awards,
  
  -- Cultural composite
  jsonb_build_object(
    'canonical_lists', COALESCE(jsonb_array_length(jsonb_object_keys(m.canonical_sources)), 0),
    'list_names', m.canonical_sources
  ) as cultural_impact,
  
  -- Coverage score (what % of metrics do we have)
  (
    (CASE WHEN em_tmdb.value IS NOT NULL THEN 1 ELSE 0 END +
     CASE WHEN em_imdb.value IS NOT NULL THEN 1 ELSE 0 END +
     CASE WHEN em_meta.value IS NOT NULL THEN 1 ELSE 0 END +
     CASE WHEN em_rt.value IS NOT NULL THEN 1 ELSE 0 END +
     CASE WHEN em_budget.value IS NOT NULL THEN 1 ELSE 0 END +
     CASE WHEN em_revenue.value IS NOT NULL THEN 1 ELSE 0 END)::DECIMAL / 6
  ) as data_completeness

FROM movies m
LEFT JOIN LATERAL (
  SELECT value FROM external_metrics 
  WHERE movie_id = m.id AND source = 'tmdb' AND metric_type = 'rating_average'
  ORDER BY fetched_at DESC LIMIT 1
) em_tmdb ON true
LEFT JOIN LATERAL (
  SELECT value FROM external_metrics 
  WHERE movie_id = m.id AND source = 'imdb' AND metric_type = 'rating_average'
  ORDER BY fetched_at DESC LIMIT 1
) em_imdb ON true
-- ... (similar joins for other metrics)
LEFT JOIN festival_nominations fn_win ON fn_win.movie_id = m.id AND fn_win.won = true
LEFT JOIN festival_nominations fn_nom ON fn_nom.movie_id = m.id
GROUP BY m.id, m.title, m.release_date, em_tmdb.value, em_imdb.value, 
         em_meta.value, em_rt.value, em_budget.value, em_revenue.value,
         em_domestic.value, em_oscar_wins.value, em_oscar_noms.value;

-- Index for fast queries
CREATE INDEX idx_composite_metrics_movie_id ON movie_composite_metrics(id);
CREATE INDEX idx_composite_metrics_completeness ON movie_composite_metrics(data_completeness);
```

### 4. Implementation Phases

#### Phase 1: Registry & Normalization (Week 1)
- [ ] Create `Cinegraph.Metrics.Registry` module
- [ ] Implement normalization functions for each metric type
- [ ] Add inflation adjustment for financial metrics
- [ ] Create composite metric calculation functions
- [ ] Write comprehensive tests

#### Phase 2: Database Updates (Week 1)
- [ ] Create weight configurations table
- [ ] Create data coverage snapshots table
- [ ] Build materialized view for composite metrics
- [ ] Add scheduled job to update coverage snapshots daily
- [ ] Migrate existing discovery weights to new system

#### Phase 3: Dashboard Core (Week 2)
- [ ] Create MetricsDashboard LiveView
- [ ] Build data sources overview component
- [ ] Build canonical lists tracking component
- [ ] Implement coverage heatmap visualization
- [ ] Add real-time data refresh

#### Phase 4: Weight Management UI (Week 2)
- [ ] Create weight configuration editor
- [ ] Add preset management (save/load/share)
- [ ] Implement A/B testing framework
- [ ] Add weight history tracking
- [ ] Build weight comparison tool

#### Phase 5: Integration (Week 3)
- [ ] Update discovery scoring to use registry
- [ ] Update search to use registry weights
- [ ] Connect CRI scoring to registry
- [ ] Update backtesting to use registry
- [ ] Add API endpoints for weight configurations

#### Phase 6: Analytics & Monitoring (Week 3)
- [ ] Track which weights perform best
- [ ] Monitor data coverage trends
- [ ] Alert on data quality issues
- [ ] Generate coverage reports
- [ ] Track user weight preferences

### 5. Dashboard Mockup Structure

```
┌─────────────────────────────────────────────────────────────────┐
│                    CINEGRAPH METRICS DASHBOARD                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────── DATA SOURCES ────────────┐  ┌─── COVERAGE ────┐ │
│  │ Source      Movies   Coverage  Status │  │                 │ │
│  │ ─────────────────────────────────────│  │  [Heatmap       │ │
│  │ TMDb        5,506    99.7%     ✅    │  │   showing       │ │
│  │ IMDb        3,922    71.0%     ✅    │  │   coverage by   │ │
│  │ Metacritic  2,016    36.5%     🟡    │  │   metric type]  │ │
│  │ RT          2,831    51.3%     🟡    │  │                 │ │
│  │ Festivals     834    15.1%     🔴    │  └─────────────────┘ │
│  │ Box Office    416     7.5%     🔴    │                      │
│  └──────────────────────────────────────┘                      │
│                                                                  │
│  ┌──────────── CANONICAL LISTS ─────────┐  ┌── WEIGHT CONFIG ─┐│
│  │ List                 Movies  Imported │  │                  ││
│  │ ─────────────────────────────────────│  │ Popular:    25% ││
│  │ 1001 Movies          1,256     ✅    │  │ Critical:   25% ││
│  │ Criterion            1,200     ❌    │  │ Industry:   25% ││
│  │ BFI Top 100            100     ❌    │  │ Cultural:   25% ││
│  │ Film Registry          875     ❌    │  │                  ││
│  └──────────────────────────────────────┘  │ [Save] [Load]    ││
│                                             └──────────────────┘│
│  ┌──────────── KEY METRICS ─────────────────────────────────┐  │
│  │ Total Movies: 5,521  |  With Ratings: 4,892 (88.6%)      │  │
│  │ With Awards: 834     |  With Box Office: 416 (7.5%)      │  │
│  │ In Lists: 1,256      |  Full Coverage: 312 (5.7%)        │  │
│  └───────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

### 6. Benefits of This Architecture

1. **Single Source of Truth**: All weights and normalization rules in one place
2. **Flexibility**: Easy to adjust weights without code changes
3. **Transparency**: Dashboard shows exactly what data we have
4. **Experimentation**: A/B test different weight configurations
5. **Scalability**: Easy to add new data sources or metrics
6. **Performance**: Materialized views for fast queries
7. **History**: Track how weights and coverage change over time

### 7. Migration Strategy

1. Start with registry module (non-breaking)
2. Add dashboard as new feature (non-breaking)
3. Gradually migrate existing systems to use registry
4. Deprecate old hardcoded weights
5. Full cutover once all systems integrated

This approach provides a clear path from our current scattered system to a unified, transparent, and easily tunable metrics infrastructure.