# MVP: Simplified Metrics System (80/20 Approach)

## Executive Summary

A minimal but complete metrics system that can be built in 1-2 weeks and expanded later without breaking changes. Focus on the core need: normalized metrics and weighted scoring with explainability.

## The 80/20 Core Architecture

### Just 3 Tables + Config Files

```sql
-- 1. METRIC DEFINITIONS (Registry)
-- Minimal schema for normalization consistency
CREATE TABLE metric_definitions (
  code TEXT PRIMARY KEY,              -- 'imdb_rating', 'oscar_wins'
  name TEXT NOT NULL,                  -- Human readable name
  category TEXT NOT NULL,             -- 'rating','award','financial','cultural','popularity'
  data_type TEXT NOT NULL,            -- 'numeric','boolean','rank'
  normalization JSONB NOT NULL,       -- {"type":"linear","min":0,"max":10}
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMP DEFAULT NOW()
);

-- 2. METRICS (Current Values)
-- One row per movie per metric (no history)
CREATE TABLE metrics (
  movie_id BIGINT NOT NULL REFERENCES movies(id),
  metric_code TEXT NOT NULL REFERENCES metric_definitions(code),
  raw_value_numeric DOUBLE PRECISION,
  raw_value_text TEXT,
  normalized_value DOUBLE PRECISION,  -- Pre-calculated [0,1]
  observed_at TIMESTAMPTZ,            -- When source says it's from
  collected_at TIMESTAMPTZ DEFAULT NOW(),
  source_ref TEXT,                    -- URL/ID for traceability
  PRIMARY KEY (movie_id, metric_code) -- Last known value only
);

-- 3. SCORES (Computed Results)
-- Versioned scoring results with explanation
CREATE TABLE scores (
  movie_id BIGINT NOT NULL REFERENCES movies(id),
  score_name TEXT NOT NULL,           -- 'discovery', 'gravitas', 'hidden_gem'
  score_version TEXT NOT NULL,        -- '1.0.0'
  value DOUBLE PRECISION NOT NULL,    -- Final score
  computed_at TIMESTAMPTZ DEFAULT NOW(),
  explain JSONB,                      -- Feature breakdown for transparency
  PRIMARY KEY (movie_id, score_name, score_version)
);

-- Indexes for performance
CREATE INDEX idx_metrics_movie ON metrics(movie_id);
CREATE INDEX idx_metrics_code ON metrics(metric_code);
CREATE INDEX idx_scores_movie ON scores(movie_id);
CREATE INDEX idx_scores_name ON scores(score_name, score_version);
```

### Configuration Over Database (For Now)

Weight profiles as versioned JSON files in the repo:

```json
// config/scores/discovery-1.0.0.json
{
  "score_name": "discovery",
  "score_version": "1.0.0",
  "description": "Balanced movie discovery score",
  
  "category_weights": {
    "rating": 0.35,
    "award": 0.20,
    "cultural": 0.20,
    "popularity": 0.15,
    "financial": 0.10
  },
  
  "metric_weights": {
    // Within 'rating' category
    "imdb_rating": 0.30,
    "tmdb_rating": 0.25,
    "metacritic_score": 0.25,
    "rt_tomatometer": 0.20,
    
    // Within 'award' category
    "oscar_wins": 0.60,
    "oscar_nominations": 0.40,
    
    // Within 'cultural' category
    "afi_top_100": 0.50,
    "criterion_collection": 0.50
  }
}
```

## Implementation (1-2 Weeks)

### Week 1: Core System

#### Day 1-2: Database & Models
```elixir
defmodule Cinegraph.Metrics.MetricDefinition do
  use Ecto.Schema
  
  schema "metric_definitions" do
    field :code, :string
    field :name, :string
    field :category, :string
    field :data_type, :string
    field :normalization, :map
    field :active, :boolean, default: true
    timestamps()
  end
end

defmodule Cinegraph.Metrics.Metric do
  use Ecto.Schema
  
  @primary_key false
  schema "metrics" do
    belongs_to :movie, Cinegraph.Movies.Movie
    field :metric_code, :string
    field :raw_value_numeric, :float
    field :raw_value_text, :string
    field :normalized_value, :float
    field :observed_at, :utc_datetime
    field :collected_at, :utc_datetime
    field :source_ref, :string
  end
end
```

#### Day 3-4: Normalization & Ingestion
```elixir
defmodule Cinegraph.Metrics.Normalizer do
  @moduledoc "Simple normalization based on metric definitions"
  
  def normalize(metric_code, raw_value) do
    definition = Repo.get!(MetricDefinition, metric_code)
    
    case definition.normalization["type"] do
      "linear" ->
        min = definition.normalization["min"] || 0
        max = definition.normalization["max"] || 1
        (raw_value - min) / (max - min) |> max(0.0) |> min(1.0)
        
      "logarithmic" ->
        threshold = definition.normalization["threshold"] || 1_000_000
        :math.log(raw_value + 1) / :math.log(threshold + 1)
        
      "boolean" ->
        if raw_value, do: 1.0, else: 0.0
        
      "custom" ->
        # Handle special cases like Oscar wins
        custom_normalize(metric_code, raw_value)
    end
  end
  
  defp custom_normalize("oscar_wins", count) when count == 0, do: 0.0
  defp custom_normalize("oscar_wins", count) when count == 1, do: 0.6
  defp custom_normalize("oscar_wins", count) when count == 2, do: 0.8
  defp custom_normalize("oscar_wins", _count), do: 1.0
end
```

#### Day 5-6: Score Computation
```elixir
defmodule Cinegraph.Metrics.Scorer do
  @moduledoc "Compute weighted scores from metrics"
  
  def compute_score(movie_id, score_name, version \\ "1.0.0") do
    # Load config from JSON file
    config = load_score_config(score_name, version)
    
    # Get all metrics for movie
    metrics = Repo.all(
      from m in Metric,
      where: m.movie_id == ^movie_id,
      select: {m.metric_code, m.normalized_value}
    ) |> Map.new()
    
    # Group by category and calculate
    explain = []
    total_score = 0.0
    
    for {category, cat_weight} <- config["category_weights"] do
      category_metrics = filter_metrics_by_category(metrics, category)
      category_score = 0.0
      
      for {code, value} <- category_metrics do
        metric_weight = config["metric_weights"][code] || 1.0
        contribution = value * metric_weight
        category_score = category_score + contribution
        
        explain = [{code, %{
          "value" => value,
          "weight" => metric_weight,
          "contribution" => contribution
        }} | explain]
      end
      
      # Normalize within category
      category_score = category_score / length(category_metrics)
      total_score = total_score + (category_score * cat_weight)
    end
    
    # Store result
    %Score{
      movie_id: movie_id,
      score_name: score_name,
      score_version: version,
      value: total_score,
      explain: Map.new(explain)
    }
    |> Repo.insert!(
      on_conflict: :replace_all,
      conflict_target: [:movie_id, :score_name, :score_version]
    )
  end
  
  defp load_score_config(name, version) do
    path = "config/scores/#{name}-#{version}.json"
    File.read!(path) |> Jason.decode!()
  end
end
```

### Week 2: UI & Integration

#### Simple LiveView Dashboard
```elixir
defmodule CinegraphWeb.MetricsDashboardLive do
  use CinegraphWeb, :live_view
  
  def render(assigns) do
    ~H"""
    <div class="metrics-dashboard-mvp">
      <!-- Coverage Overview -->
      <div class="coverage-summary">
        <h2>Metric Coverage</h2>
        <table>
          <thead>
            <tr>
              <th>Metric</th>
              <th>Coverage</th>
              <th>Avg Value</th>
            </tr>
          </thead>
          <tbody>
            <%= for stat <- @coverage_stats do %>
              <tr>
                <td><%= stat.name %></td>
                <td>
                  <div class="progress">
                    <div class="bar" style={"width: #{stat.coverage_pct * 100}%"}></div>
                  </div>
                  <%= Float.round(stat.coverage_pct * 100, 1) %>%
                </td>
                <td><%= Float.round(stat.avg_norm || 0, 2) %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
      
      <!-- Score Testing -->
      <div class="score-tester">
        <h2>Test Scoring</h2>
        <input type="text" phx-change="search_movie" placeholder="Search movie..." />
        
        <%= if @selected_movie do %>
          <div class="movie-scores">
            <h3><%= @selected_movie.title %></h3>
            
            <!-- Show metrics -->
            <div class="metrics-list">
              <%= for {code, value} <- @movie_metrics do %>
                <div class="metric-row">
                  <span><%= code %>:</span>
                  <strong><%= Float.round(value, 2) %></strong>
                </div>
              <% end %>
            </div>
            
            <!-- Calculate score -->
            <button phx-click="calculate_score">Calculate Discovery Score</button>
            
            <%= if @score_result do %>
              <div class="score-result">
                <h4>Discovery Score: <%= Float.round(@score_result.value, 3) %></h4>
                
                <!-- Explanation -->
                <details>
                  <summary>See breakdown</summary>
                  <pre><%= Jason.encode!(@score_result.explain, pretty: true) %></pre>
                </details>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
  
  def mount(_params, _session, socket) do
    {:ok, socket
      |> assign(:coverage_stats, calculate_coverage())
      |> assign(:selected_movie, nil)
      |> assign(:score_result, nil)}
  end
  
  defp calculate_coverage do
    Repo.all(
      from m in Metric,
      join: md in MetricDefinition, on: m.metric_code == md.code,
      group_by: [md.code, md.name],
      select: %{
        code: md.code,
        name: md.name,
        coverage_pct: fragment("COUNT(*)::float / (SELECT COUNT(*) FROM movies)"),
        avg_norm: avg(m.normalized_value)
      }
    )
  end
end
```

#### Coverage View (Materialized)
```sql
CREATE MATERIALIZED VIEW mv_metric_coverage AS
SELECT
  md.code,
  md.name,
  md.category,
  COUNT(m.movie_id) AS movies_with_value,
  (SELECT COUNT(*) FROM movies) AS total_movies,
  COUNT(m.movie_id)::float / NULLIF((SELECT COUNT(*) FROM movies), 0) AS coverage_pct,
  AVG(m.normalized_value) AS avg_normalized,
  MIN(m.normalized_value) AS min_normalized,
  MAX(m.normalized_value) AS max_normalized
FROM metric_definitions md
LEFT JOIN metrics m ON m.metric_code = md.code
GROUP BY md.code, md.name, md.category;

-- Refresh hourly via cron
-- 0 * * * * psql -c "REFRESH MATERIALIZED VIEW CONCURRENTLY mv_metric_coverage;"
```

## Data Sources to Start With (Week 1)

### Phase 1: Essential Metrics (15 total)
```elixir
# Seed these metric_definitions
[
  # Ratings (4)
  %{code: "tmdb_rating", category: "rating", normalization: %{type: "linear", min: 0, max: 10}},
  %{code: "imdb_rating", category: "rating", normalization: %{type: "linear", min: 0, max: 10}},
  %{code: "metacritic_score", category: "rating", normalization: %{type: "linear", min: 0, max: 100}},
  %{code: "rt_tomatometer", category: "rating", normalization: %{type: "linear", min: 0, max: 100}},
  
  # Awards (3)
  %{code: "oscar_wins", category: "award", normalization: %{type: "custom"}},
  %{code: "oscar_nominations", category: "award", normalization: %{type: "logarithmic", threshold: 10}},
  %{code: "festival_wins", category: "award", normalization: %{type: "logarithmic", threshold: 5}},
  
  # Cultural (4)
  %{code: "afi_top_100", category: "cultural", normalization: %{type: "boolean"}},
  %{code: "criterion_collection", category: "cultural", normalization: %{type: "boolean"}},
  %{code: "sight_sound", category: "cultural", normalization: %{type: "boolean"}},
  %{code: "1001_movies", category: "cultural", normalization: %{type: "boolean"}},
  
  # Financial (2)
  %{code: "box_office", category: "financial", normalization: %{type: "logarithmic", threshold: 1_000_000_000}},
  %{code: "budget", category: "financial", normalization: %{type: "logarithmic", threshold: 200_000_000}},
  
  # Popularity (2)
  %{code: "tmdb_popularity", category: "popularity", normalization: %{type: "logarithmic", threshold: 1000}},
  %{code: "imdb_votes", category: "popularity", normalization: %{type: "logarithmic", threshold: 1_000_000}}
]
```

### Simple Adapters
```elixir
defmodule Cinegraph.Metrics.Adapters.TMDb do
  def fetch_and_store(movie_id) do
    movie = Repo.get!(Movie, movie_id)
    
    if movie.tmdb_data do
      # Extract and store rating
      upsert_metric(movie_id, "tmdb_rating", 
        movie.tmdb_data["vote_average"],
        movie.tmdb_data["release_date"])
      
      # Extract and store popularity
      upsert_metric(movie_id, "tmdb_popularity",
        movie.tmdb_data["popularity"],
        DateTime.utc_now())
    end
  end
  
  defp upsert_metric(movie_id, code, raw_value, observed_at) do
    normalized = Normalizer.normalize(code, raw_value)
    
    %Metric{}
    |> Metric.changeset(%{
      movie_id: movie_id,
      metric_code: code,
      raw_value_numeric: raw_value,
      normalized_value: normalized,
      observed_at: observed_at
    })
    |> Repo.insert!(
      on_conflict: :replace_all,
      conflict_target: [:movie_id, :metric_code]
    )
  end
end
```

## MVP vs Full System Comparison

### MVP Advantages ✅

1. **Simplicity**
   - 3 tables vs 7+ tables
   - 200 lines of code vs 2000+
   - 1-2 weeks vs 8-10 weeks

2. **Immediate Value**
   - Working system in days
   - Real normalized metrics
   - Actual scoring with explanations

3. **Easy to Understand**
   - JSON configs are readable
   - Simple data model
   - Clear upgrade path

4. **Lower Risk**
   - Test core assumptions first
   - Validate with real users
   - Iterate based on feedback

5. **Performance**
   - Fewer joins
   - Simple caching (just scores table)
   - No complex aggregations

### MVP Limitations ⚠️

1. **No History**
   - Can't track metric changes over time
   - No trend analysis
   - Single snapshot only

2. **No User Personalization**
   - One scoring profile for all
   - No ML optimization
   - No A/B testing

3. **Limited Extensibility**
   - Person quality metrics need new approach
   - No real-time updates
   - Basic coverage stats only

4. **Manual Processes**
   - Config changes require deploy
   - No UI for weight adjustment
   - Coverage refresh is manual

### Full System Advantages 🚀

1. **Complete Feature Set**
   - Time-series tracking
   - ML optimization
   - Real-time updates
   - Person quality metrics

2. **Enterprise Ready**
   - Audit trails
   - User personalization
   - A/B testing
   - Advanced caching

3. **Rich UI**
   - Interactive dashboards
   - Weight adjustment
   - Visual analytics
   - Trend detection

### Full System Disadvantages ❌

1. **Complexity**
   - 7+ tables
   - Multiple GenServers
   - Complex caching layers
   - Harder to debug

2. **Time Investment**
   - 8-10 weeks minimum
   - Requires full team
   - Extensive testing needed

3. **Over-Engineering Risk**
   - May build features not needed
   - Premature optimization
   - Complex for simple use cases

## Migration Path (No Breaking Changes)

### From MVP → Full System

#### Step 1: Add History (Week 3)
```sql
-- Add history table
CREATE TABLE metrics_history AS SELECT * FROM metrics WHERE false;
ALTER TABLE metrics_history ADD COLUMN id SERIAL PRIMARY KEY;

-- Trigger to copy on update
CREATE TRIGGER save_metric_history
  AFTER UPDATE ON metrics
  FOR EACH ROW
  INSERT INTO metrics_history SELECT OLD.*;
```

#### Step 2: Add Profiles (Week 4)
```sql
-- Add profile tables
CREATE TABLE weight_profiles (...);
CREATE TABLE profile_metric_weights (...);

-- Scores table stays same, just add profile_id
ALTER TABLE scores ADD COLUMN profile_id INTEGER;
```

#### Step 3: Add ML (Week 5-6)
- Keep JSON configs as "system" profiles
- Add ML-generated profiles to database
- A/B test via profile_id in scores

#### Step 4: Add Time-Series (Week 7)
```sql
-- Add TimescaleDB
CREATE TABLE metric_timeseries (...);
SELECT create_hypertable('metric_timeseries', 'time');

-- Backfill from metrics_history
INSERT INTO metric_timeseries SELECT * FROM metrics_history;
```

#### Step 5: Add Person Quality (Week 8)
- New category in metric_definitions
- Compute PQS separately
- Store as regular metrics

## Success Criteria

### Week 1 Checkpoint
- [ ] 15 metrics defined and normalized
- [ ] 1000+ movies with metrics
- [ ] Basic scoring working
- [ ] Coverage view created

### Week 2 Checkpoint
- [ ] Dashboard showing coverage
- [ ] Score calculation with explanation
- [ ] 3 score configs (discovery, quality, hidden_gem)
- [ ] API endpoint for scores

### Month 1 Success
- [ ] All movies have basic metrics
- [ ] Team using dashboard daily
- [ ] Scores integrated in main UI
- [ ] Clear data quality insights

## Recommended Approach

**Start with MVP** because:

1. **Proves Value Fast**: See if metrics actually improve discovery
2. **Real User Feedback**: Learn what's actually needed
3. **Lower Risk**: Smaller investment, easier pivots
4. **Team Learning**: Understand the domain better
5. **Clear Upgrade Path**: Can evolve to full system

**When to Upgrade**:
- When you need user personalization (profiles)
- When you need trend analysis (time-series)
- When you have ML requirements (optimization)
- When you hit performance limits (advanced caching)

## Implementation Checklist

### Day 1-2
- [ ] Create 3 tables
- [ ] Create Ecto schemas
- [ ] Seed 15 metric_definitions
- [ ] Write Normalizer module

### Day 3-4
- [ ] Build TMDb adapter
- [ ] Build IMDb adapter
- [ ] Build Festival adapter
- [ ] Test normalization

### Day 5-6
- [ ] Create Scorer module
- [ ] Write discovery-1.0.0.json config
- [ ] Compute first scores
- [ ] Add explain JSONB

### Day 7-8
- [ ] Build coverage materialized view
- [ ] Create basic LiveView dashboard
- [ ] Add movie search
- [ ] Show score breakdown

### Day 9-10
- [ ] Add API endpoint
- [ ] Create cron for coverage refresh
- [ ] Add remaining adapters
- [ ] Documentation

## Conclusion

The MVP gives you 80% of the value with 20% of the effort. It's production-ready, provides real value, and can grow into the full system without breaking changes. Start here, learn what matters, then expand based on actual needs rather than anticipated ones.