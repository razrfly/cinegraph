# Movie Data Architecture Reorganization

## Problem Analysis

The current architecture has several issues:

1. **Mixed Data Sources in Movie Table**: The `movies` table contains fields from different sources without clear attribution:
   - TMDb data: `vote_average`, `vote_count`, `popularity`
   - OMDb data: `awards_text`, `box_office_domestic`
   - Financial data: `budget`, `revenue` (unclear source/reliability)

2. **Redundant Tables**: We have 4 tables (`external_sources`, `external_ratings`, `external_recommendations`, plus raw `tmdb_data`/`omdb_data` in movies) to handle data from only 2 sources (TMDb, OMDb).

3. **No Update Tracking**: Volatile fields like ratings and financials change over time but we don't track when/how they were updated.

4. **Unclear Data Quality**: No way to know which financial numbers are estimates vs. actuals, or which ratings are fresh vs. stale.

## Proposed Solution: Unified External Metrics System

### Core Principles
1. **Single Source of Truth**: One table for all external metrics with clear source attribution
2. **Temporal Awareness**: Track when data was fetched and allow historical tracking
3. **Flexible Schema**: Handle any type of metric without schema changes
4. **Clear Provenance**: Always know where data came from and when

### Database Schema

#### 1. Simplified Movie Table
Remove all subjective/external fields from the `movies` table:

```elixir
schema "movies" do
  # Core Identity (immutable)
  field :tmdb_id, :integer
  field :imdb_id, :string
  
  # Core Facts (rarely change)
  field :title, :string
  field :original_title, :string
  field :release_date, :date
  field :runtime, :integer
  field :overview, :string
  field :tagline, :string
  field :original_language, :string
  field :status, :string
  field :adult, :boolean
  field :homepage, :string
  
  # Media References
  field :poster_path, :string
  field :backdrop_path, :string
  field :collection_id, :integer
  
  # Raw data storage (for reference/debugging)
  field :tmdb_data, :map
  field :omdb_data, :map
  
  # Import tracking
  field :import_status, :string
  field :canonical_sources, :map
  
  timestamps()
end
```

#### 2. Unified External Metrics Table

Replace `external_ratings` with a more flexible `external_metrics` table:

```elixir
schema "external_metrics" do
  belongs_to :movie, Movie
  
  # Source identification
  field :source, :string  # "tmdb", "omdb", "boxofficemojo", etc.
  field :metric_type, :string  # See types below
  
  # The actual data
  field :value, :float  # Primary numeric value
  field :text_value, :string  # For text metrics (awards, etc.)
  field :metadata, :map  # Additional context
  
  # Temporal tracking
  field :fetched_at, :utc_datetime
  field :valid_until, :utc_datetime  # For caching/staleness
  
  timestamps()
end
```

**Metric Types:**
- **Ratings**: `rating_imdb`, `rating_rotten_tomatoes`, `rating_metacritic`, `rating_tmdb`
- **Engagement**: `votes_imdb`, `votes_tmdb`, `popularity_tmdb`
- **Financial**: `budget`, `revenue_worldwide`, `revenue_domestic`, `revenue_international`, `box_office_opening`
- **Awards**: `awards_summary`, `oscar_wins`, `oscar_nominations`
- **Critical**: `metascore`, `tomatometer`, `audience_score`

#### 3. Simplified Recommendations Table

Keep `external_recommendations` but simplify:

```elixir
schema "movie_recommendations" do
  belongs_to :source_movie, Movie
  belongs_to :recommended_movie, Movie
  
  field :source, :string  # "tmdb", "omdb"
  field :type, :string  # "similar", "recommended"
  field :rank, :integer  # Position in recommendation list
  field :score, :float  # Similarity/relevance score
  
  field :fetched_at, :utc_datetime
  timestamps()
end
```

### Migration Strategy

```elixir
defmodule MigrateToUnifiedMetrics do
  def up do
    # 1. Create new external_metrics table
    create table(:external_metrics) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :source, :string, null: false
      add :metric_type, :string, null: false
      add :value, :float
      add :text_value, :text
      add :metadata, :map, default: %{}
      add :fetched_at, :utc_datetime, null: false
      add :valid_until, :utc_datetime
      timestamps()
    end
    
    create index(:external_metrics, [:movie_id])
    create index(:external_metrics, [:source])
    create index(:external_metrics, [:metric_type])
    create index(:external_metrics, [:fetched_at])
    create unique_index(:external_metrics, [:movie_id, :source, :metric_type])
    
    # 2. Migrate existing data
    execute """
    INSERT INTO external_metrics (movie_id, source, metric_type, value, fetched_at, inserted_at, updated_at)
    SELECT 
      id, 'tmdb', 'rating_tmdb', vote_average, NOW(), NOW(), NOW()
    FROM movies WHERE vote_average IS NOT NULL
    """
    
    execute """
    INSERT INTO external_metrics (movie_id, source, metric_type, value, fetched_at, inserted_at, updated_at)
    SELECT 
      id, 'tmdb', 'votes_tmdb', vote_count, NOW(), NOW(), NOW()
    FROM movies WHERE vote_count IS NOT NULL
    """
    
    # ... similar for other fields
    
    # 3. Create view for backward compatibility
    execute """
    CREATE VIEW movies_with_metrics AS
    SELECT 
      m.*,
      tmdb_rating.value as vote_average,
      tmdb_votes.value as vote_count,
      tmdb_pop.value as popularity,
      budget.value as budget,
      revenue.value as revenue
    FROM movies m
    LEFT JOIN external_metrics tmdb_rating ON m.id = tmdb_rating.movie_id 
      AND tmdb_rating.source = 'tmdb' AND tmdb_rating.metric_type = 'rating_tmdb'
    LEFT JOIN external_metrics tmdb_votes ON m.id = tmdb_votes.movie_id 
      AND tmdb_votes.source = 'tmdb' AND tmdb_votes.metric_type = 'votes_tmdb'
    -- etc...
    """
    
    # 4. Drop old columns from movies table (in separate migration after testing)
  end
end
```

### API Usage Examples

```elixir
# Store TMDb data
def store_tmdb_metrics(movie, tmdb_data) do
  metrics = [
    %{metric_type: "rating_tmdb", value: tmdb_data["vote_average"]},
    %{metric_type: "votes_tmdb", value: tmdb_data["vote_count"]},
    %{metric_type: "popularity_tmdb", value: tmdb_data["popularity"]},
    %{metric_type: "budget", value: tmdb_data["budget"], 
     metadata: %{"currency" => "USD", "status" => "reported"}},
    %{metric_type: "revenue_worldwide", value: tmdb_data["revenue"],
     metadata: %{"currency" => "USD", "status" => "reported"}}
  ]
  
  Enum.each(metrics, fn metric ->
    %ExternalMetric{}
    |> ExternalMetric.changeset(Map.merge(metric, %{
      movie_id: movie.id,
      source: "tmdb",
      fetched_at: DateTime.utc_now()
    }))
    |> Repo.insert(on_conflict: :replace_all)
  end)
end

# Store OMDb data
def store_omdb_metrics(movie, omdb_data) do
  metrics = []
  
  # Parse Rotten Tomatoes rating
  if rt = parse_rating(omdb_data["Ratings"], "Rotten Tomatoes") do
    metrics = metrics ++ [%{metric_type: "rating_rotten_tomatoes", value: rt}]
  end
  
  # Parse box office
  if box_office = parse_money(omdb_data["BoxOffice"]) do
    metrics = metrics ++ [%{
      metric_type: "box_office_domestic", 
      value: box_office,
      metadata: %{"currency" => "USD", "market" => "domestic"}
    }]
  end
  
  # Store awards as text
  if awards = omdb_data["Awards"] do
    metrics = metrics ++ [%{
      metric_type: "awards_summary",
      text_value: awards,
      metadata: parse_awards_counts(awards)
    }]
  end
  
  # Insert all metrics...
end

# Query latest metrics for a movie
def get_movie_with_metrics(movie_id) do
  movie = Repo.get!(Movie, movie_id)
  
  metrics = 
    from(m in ExternalMetric,
      where: m.movie_id == ^movie_id,
      distinct: [m.source, m.metric_type],
      order_by: [desc: m.fetched_at]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.source)
  
  %{movie: movie, metrics: metrics}
end

# Get historical data for analysis
def get_metric_history(movie_id, metric_type, days_back \\ 30) do
  from(m in ExternalMetric,
    where: m.movie_id == ^movie_id and m.metric_type == ^metric_type,
    where: m.fetched_at > ago(^days_back, "day"),
    order_by: [asc: m.fetched_at]
  )
  |> Repo.all()
end
```

### Benefits

1. **Clear Attribution**: Every piece of data has a clear source and timestamp
2. **Historical Tracking**: Can track how ratings/revenue change over time
3. **Flexible Schema**: Easy to add new metrics without migrations
4. **Reduced Complexity**: 2 focused tables instead of 4+ overlapping ones
5. **Better Caching**: `valid_until` field enables smart caching strategies
6. **Easier Filtering**: Can easily filter/search by specific metrics
7. **Source Comparison**: Can store same metric from multiple sources (e.g., budget from TMDb vs. BoxOfficeMojo)

### Implementation Phases

**Phase 1: Create Infrastructure**
- Create `external_metrics` table
- Create backward-compatible view
- Update import pipeline to write to both old and new structure

**Phase 2: Migration**
- Migrate existing data to new structure
- Update all queries to use new structure
- Test thoroughly

**Phase 3: Cleanup**
- Remove deprecated columns from movies table
- Drop external_ratings table (if no longer needed)
- Remove redundant code

**Phase 4: Enhancements**
- Add metric freshness indicators to UI
- Implement historical tracking features
- Add source quality scoring

### Search/Filter Implications

With this structure, searching and filtering becomes more powerful:

```elixir
# Find highly-rated recent movies
from(m in Movie,
  join: metric in ExternalMetric,
  on: metric.movie_id == m.id,
  where: metric.metric_type == "rating_imdb" and metric.value > 8.0,
  where: m.release_date > ^one_year_ago,
  distinct: true
)

# Find movies with growing popularity
from(m in Movie,
  join: old in ExternalMetric,
  on: old.movie_id == m.id,
  join: new in ExternalMetric,
  on: new.movie_id == m.id,
  where: old.metric_type == "popularity_tmdb",
  where: new.metric_type == "popularity_tmdb",
  where: old.fetched_at < ago(30, "day"),
  where: new.fetched_at > ago(1, "day"),
  where: new.value > old.value * 1.5
)

# Compare sources
from(m in Movie,
  join: tmdb in ExternalMetric,
  on: tmdb.movie_id == m.id and tmdb.source == "tmdb",
  join: omdb in ExternalMetric,
  on: omdb.movie_id == m.id and omdb.source == "omdb",
  where: tmdb.metric_type == "budget",
  where: omdb.metric_type == "budget",
  where: abs(tmdb.value - omdb.value) > 1000000
)
```

## Alternative: Enhanced Current Structure

If a complete reorganization is too disruptive, we could enhance the current structure:

1. **Add `data_source` field to movies** for each subjective field
2. **Add `fetched_at` timestamps** for each group of fields
3. **Use `external_ratings` more extensively** as originally proposed
4. **Create audit tables** to track changes over time

However, this approach would:
- Add more complexity to the movies table
- Make it harder to add new metrics
- Not solve the core attribution problem
- Still require significant refactoring

## Recommendation

Implement the **Unified External Metrics System**. It's a cleaner, more maintainable solution that:
- Solves all identified problems
- Provides better long-term flexibility
- Enables powerful new features
- Maintains backward compatibility during transition

The slight increase in query complexity is offset by:
- Much clearer data model
- Better performance (smaller movies table)
- Easier debugging and maintenance
- More powerful analytics capabilities