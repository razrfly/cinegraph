# Person-Based Quality Metrics Integration

## How Person Quality Scores Fit Into Our Unified Metrics System

Person-based quality metrics are **composite derived metrics** that aggregate multiple data points about filmmakers and actors to create a "gravitas" score for movies. This is more complex than simple metrics but fits perfectly into our architecture with some additions.

## Integration Architecture

### 1. Person Quality Score (PQS) as a New Metric Category

In our `metric_definitions` table, we add a new category:

```sql
-- Add new category for person-based metrics
INSERT INTO metric_definitions (code, name, category, source, data_type, normalization_type) VALUES
-- Director metrics
('director_pqs', 'Director Quality Score', 'person_quality', 'calculated', 'numeric', 'linear'),
('director_festival_score', 'Director Festival Performance', 'person_quality', 'calculated', 'numeric', 'linear'),
('director_canonical_score', 'Director Canonical Recognition', 'person_quality', 'calculated', 'numeric', 'linear'),
('director_longevity_score', 'Director Career Longevity', 'person_quality', 'calculated', 'numeric', 'sigmoid'),
('director_peer_score', 'Director Peer Recognition', 'person_quality', 'calculated', 'numeric', 'linear'),

-- Actor metrics  
('lead_actor_pqs', 'Lead Actor Quality Score', 'person_quality', 'calculated', 'numeric', 'linear'),
('supporting_cast_pqs', 'Supporting Cast Quality', 'person_quality', 'calculated', 'numeric', 'linear'),
('cast_awards_score', 'Cast Awards Performance', 'person_quality', 'calculated', 'numeric', 'linear'),
('cast_versatility_score', 'Cast Genre Versatility', 'person_quality', 'calculated', 'numeric', 'linear'),

-- Composite movie metric
('movie_gravitas_score', 'Movie Gravitas Score', 'person_quality', 'calculated', 'numeric', 'linear');
```

### 2. New Database Tables for Person Metrics

```sql
-- Store calculated person quality scores
CREATE TABLE person_quality_scores (
  id SERIAL PRIMARY KEY,
  person_id INTEGER REFERENCES people(id),
  role_type VARCHAR(20), -- 'director', 'actor', 'writer', 'composer'
  
  -- Component scores (0-1 normalized)
  festival_score FLOAT,
  canonical_score FLOAT,
  longevity_score FLOAT,
  peer_recognition_score FLOAT,
  cultural_impact_score FLOAT,
  awards_score FLOAT,
  collaboration_quality_score FLOAT,
  genre_versatility_score FLOAT,
  career_arc_score FLOAT,
  
  -- Composite score
  total_pqs FLOAT NOT NULL, -- Weighted combination
  percentile_rank FLOAT, -- Where they rank among peers
  
  -- Metadata
  calculation_version VARCHAR(20),
  calculated_at TIMESTAMP NOT NULL DEFAULT NOW(),
  films_analyzed INTEGER,
  
  -- Caching
  valid_until TIMESTAMP,
  
  UNIQUE(person_id, role_type)
);

-- Store movie gravitas scores (derived from person scores)
CREATE TABLE movie_gravitas_scores (
  id SERIAL PRIMARY KEY,
  movie_id INTEGER REFERENCES movies(id) UNIQUE,
  
  -- Component scores
  director_pqs FLOAT,
  director_weight FLOAT DEFAULT 0.6,
  
  lead_actors_avg_pqs FLOAT,
  lead_actors_weight FLOAT DEFAULT 0.3,
  
  supporting_cast_avg_pqs FLOAT,
  supporting_cast_weight FLOAT DEFAULT 0.1,
  
  -- Key crew (future expansion)
  cinematographer_pqs FLOAT,
  composer_pqs FLOAT,
  writer_pqs FLOAT,
  
  -- Final score
  total_gravitas_score FLOAT NOT NULL,
  
  -- Metadata
  calculated_at TIMESTAMP NOT NULL DEFAULT NOW(),
  people_count INTEGER,
  calculation_version VARCHAR(20),
  
  -- For tracking what changed
  components_hash VARCHAR(64) -- MD5 of all component IDs
);

-- Track person collaboration networks (for peer recognition)
CREATE TABLE person_collaborations (
  id SERIAL PRIMARY KEY,
  person_a_id INTEGER REFERENCES people(id),
  person_b_id INTEGER REFERENCES people(id),
  collaboration_count INTEGER DEFAULT 1,
  
  -- Quality metrics of their collaborations
  avg_movie_score FLOAT,
  best_movie_score FLOAT,
  total_revenue BIGINT,
  total_awards INTEGER,
  
  UNIQUE(person_a_id, person_b_id)
);

-- Career trajectory tracking
CREATE TABLE person_career_metrics (
  id SERIAL PRIMARY KEY,
  person_id INTEGER REFERENCES people(id),
  year INTEGER,
  
  -- Annual metrics
  films_count INTEGER,
  avg_film_score FLOAT,
  awards_won INTEGER,
  nominations INTEGER,
  box_office_total BIGINT,
  
  -- Trajectory indicators
  momentum_score FLOAT, -- Rising/falling career
  consistency_score FLOAT, -- How consistent their quality is
  
  UNIQUE(person_id, year)
);
```

### 3. Calculation Pipeline with Oban Pro

```elixir
defmodule Cinegraph.PersonMetrics.Calculator do
  @moduledoc """
  Calculates Person Quality Scores using our unified metrics system
  """
  
  use Oban.Pro.Workflow
  
  def calculate_all_person_scores do
    # Workflow for calculating all person scores
    workflow()
    |> add(:fetch_directors, FetchAllDirectors)
    |> add(:fetch_actors, FetchAllActors)
    |> add(:calc_director_scores, CalculateDirectorScores, 
           deps: [:fetch_directors])
    |> add(:calc_actor_scores, CalculateActorScores, 
           deps: [:fetch_actors])
    |> add(:calc_movie_gravitas, CalculateMovieGravitas,
           deps: [:calc_director_scores, :calc_actor_scores])
    |> add(:update_cache, UpdatePersonMetricsCache,
           deps: [:calc_movie_gravitas])
    |> Oban.insert_all()
  end
  
  def calculate_director_pqs(director_id) do
    director = Repo.get!(Person, director_id)
    
    # Get all movies they directed
    movies = get_directed_movies(director_id)
    
    # 1. Festival Performance (40% weight)
    festival_score = calculate_festival_score(movies)
    
    # 2. Canonical Recognition (25% weight)  
    canonical_score = calculate_canonical_presence(movies)
    
    # 3. Career Longevity (20% weight)
    longevity_score = calculate_longevity(director.career_start)
    
    # 4. Peer Recognition (10% weight)
    peer_score = calculate_peer_collaborations(director_id)
    
    # 5. Cultural Impact (5% weight)
    cultural_score = calculate_cultural_impact(movies)
    
    # Weighted combination
    total_pqs = 
      festival_score * 0.40 +
      canonical_score * 0.25 +
      longevity_score * 0.20 +
      peer_score * 0.10 +
      cultural_score * 0.05
    
    # Store in database
    %PersonQualityScore{
      person_id: director_id,
      role_type: "director",
      festival_score: festival_score,
      canonical_score: canonical_score,
      longevity_score: longevity_score,
      peer_recognition_score: peer_score,
      cultural_impact_score: cultural_score,
      total_pqs: total_pqs,
      percentile_rank: calculate_percentile_rank(total_pqs, "director"),
      films_analyzed: length(movies),
      calculation_version: "v1.0"
    }
    |> Repo.insert!(
      on_conflict: :replace_all,
      conflict_target: [:person_id, :role_type]
    )
  end
  
  def calculate_movie_gravitas(movie_id) do
    movie = Repo.get!(Movie, movie_id) |> Repo.preload(:credits)
    
    # Get director PQS
    director = get_director(movie)
    director_pqs = get_or_calculate_pqs(director.id, "director")
    
    # Get lead actors' PQS
    lead_actors = get_lead_actors(movie)
    lead_actors_pqs = 
      lead_actors
      |> Enum.map(& get_or_calculate_pqs(&1.id, "actor"))
      |> Enum.sum()
      |> Kernel./(max(length(lead_actors), 1))
    
    # Get supporting cast PQS
    supporting = get_supporting_cast(movie)
    supporting_pqs = 
      supporting
      |> Enum.map(& get_or_calculate_pqs(&1.id, "actor"))
      |> Enum.sum()
      |> Kernel./(max(length(supporting), 1))
    
    # Calculate weighted gravitas
    gravitas = 
      director_pqs * 0.6 +
      lead_actors_pqs * 0.3 +
      supporting_pqs * 0.1
    
    # Store in our metrics system
    %MovieGravitasScore{
      movie_id: movie_id,
      director_pqs: director_pqs,
      lead_actors_avg_pqs: lead_actors_pqs,
      supporting_cast_avg_pqs: supporting_pqs,
      total_gravitas_score: gravitas,
      people_count: 1 + length(lead_actors) + length(supporting)
    }
    |> Repo.insert!(
      on_conflict: :replace_all,
      conflict_target: :movie_id
    )
    
    # Also store in external_metrics for unified access
    Cinegraph.ExternalSources.upsert_external_metric(%{
      movie_id: movie_id,
      source: "cinegraph",
      metric_type: "gravitas_score",
      value: gravitas,
      metadata: %{
        "director_pqs" => director_pqs,
        "cast_pqs" => lead_actors_pqs
      }
    })
  end
  
  defp calculate_festival_score(movies) do
    # Use our existing festival_nominations table
    wins = count_festival_wins(movies)
    nominations = count_festival_nominations(movies)
    
    # Normalize using our registry's normalization
    Registry.normalize_value("director_festival_wins", wins)
  end
  
  defp calculate_peer_collaborations(person_id) do
    # Query person_collaborations table
    collaborations = 
      Repo.all(
        from pc in PersonCollaboration,
        where: pc.person_a_id == ^person_id or pc.person_b_id == ^person_id,
        select: {pc.collaboration_count, pc.avg_movie_score}
      )
    
    # Weight by quality of collaborator
    weighted_score = 
      collaborations
      |> Enum.map(fn {count, avg_score} -> 
        count * avg_score * get_collaborator_pqs()
      end)
      |> Enum.sum()
    
    # Normalize
    Registry.normalize_value("peer_collaboration_score", weighted_score)
  end
end
```

### 4. Integration with Unified Metrics Dashboard

Add a new tab to our LiveView dashboard:

```elixir
defmodule CinegraphWeb.Admin.PersonMetricsLive do
  use CinegraphWeb, :live_view
  
  def render(assigns) do
    ~H"""
    <div class="person-metrics-dashboard">
      <!-- Person Quality Rankings -->
      <div class="pqs-rankings">
        <h3>Top Directors by PQS</h3>
        <table>
          <thead>
            <tr>
              <th>Rank</th>
              <th>Director</th>
              <th>PQS</th>
              <th>Festival</th>
              <th>Canonical</th>
              <th>Longevity</th>
              <th>Films</th>
            </tr>
          </thead>
          <tbody>
            <%= for {director, rank} <- Enum.with_index(@top_directors, 1) do %>
              <tr>
                <td>#<%= rank %></td>
                <td><%= director.name %></td>
                <td>
                  <div class="pqs-score">
                    <%= Float.round(director.total_pqs, 3) %>
                  </div>
                </td>
                <td><%= score_bar(director.festival_score) %></td>
                <td><%= score_bar(director.canonical_score) %></td>
                <td><%= score_bar(director.longevity_score) %></td>
                <td><%= director.films_analyzed %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
      
      <!-- Movie Gravitas Scores -->
      <div class="gravitas-explorer">
        <h3>Movies by Gravitas Score</h3>
        
        <!-- Interactive scatter plot -->
        <div class="gravitas-plot">
          <canvas phx-hook="GravitasScatterPlot" 
                  data-movies={Jason.encode!(@movies_with_gravitas)} />
        </div>
        
        <!-- Gravitas vs Traditional Metrics -->
        <div class="correlation-analysis">
          <h4>Gravitas Correlation with Other Metrics</h4>
          <div class="correlation-grid">
            <div>IMDb Rating: <%= @correlations.imdb %></div>
            <div>Box Office: <%= @correlations.box_office %></div>
            <div>Festival Wins: <%= @correlations.festivals %></div>
            <div>Cultural Impact: <%= @correlations.cultural %></div>
          </div>
        </div>
      </div>
      
      <!-- Career Trajectory Viewer -->
      <div class="career-trajectory">
        <h3>Career Trajectory Analysis</h3>
        <input type="text" phx-keyup="search_person" placeholder="Search person..." />
        
        <%= if @selected_person do %>
          <div class="trajectory-chart">
            <canvas phx-hook="CareerTrajectory" 
                    data-metrics={Jason.encode!(@career_metrics)} />
          </div>
          
          <div class="momentum-indicator">
            <%= if @selected_person.momentum_score > 0 do %>
              <span class="rising">↗ Rising (<%= @selected_person.momentum_score %>)</span>
            <% else %>
              <span class="falling">↘ Declining (<%= @selected_person.momentum_score %>)</span>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
```

### 5. Caching Strategy for Performance

```elixir
defmodule Cinegraph.PersonMetrics.Cache do
  @moduledoc """
  Multi-tier caching for expensive person quality calculations
  """
  
  # Tier 1: In-memory cache (Cachex)
  def get_person_pqs(person_id, role) do
    key = "person:#{person_id}:#{role}:pqs"
    
    Cachex.fetch(:metrics_cache, key, fn ->
      # Tier 2: Database cache
      case Repo.get_by(PersonQualityScore, 
                       person_id: person_id, 
                       role_type: role) do
        nil ->
          # Tier 3: Calculate fresh
          {:commit, calculate_fresh_pqs(person_id, role), ttl: :timer.hours(24)}
        
        %{valid_until: valid_until} = score ->
          if DateTime.compare(valid_until, DateTime.utc_now()) == :gt do
            {:commit, score.total_pqs, ttl: :timer.hours(1)}
          else
            # Recalculate in background, return stale for now
            spawn(fn -> calculate_fresh_pqs(person_id, role) end)
            {:commit, score.total_pqs, ttl: :timer.minutes(5)}
          end
      end
    end)
  end
  
  # Invalidation on major changes
  def invalidate_person(person_id) do
    Cachex.del(:metrics_cache, "person:#{person_id}:*")
    
    # Mark database entries as stale
    from(p in PersonQualityScore, where: p.person_id == ^person_id)
    |> Repo.update_all(set: [valid_until: DateTime.utc_now()])
  end
end
```

### 6. Machine Learning Enhancement

```elixir
defmodule Cinegraph.PersonMetrics.ML do
  @moduledoc """
  ML models to predict person quality and movie success
  """
  
  import Nx.Defn
  alias Scholar.Linear.LinearRegression
  
  def train_gravitas_predictor do
    # Get training data: movies with known success metrics
    training_data = get_successful_movies_with_gravitas()
    
    # Features: director PQS, cast PQS, genre, budget, etc.
    features = build_feature_matrix(training_data)
    
    # Labels: box office, ratings, awards
    labels = build_success_labels(training_data)
    
    # Train model to predict success from gravitas
    model = LinearRegression.fit(features, labels)
    
    # This tells us how important gravitas is!
    gravitas_importance = Nx.to_number(model.coefficients[0])
    
    # Store in our weight profiles
    update_weight_profile("ml_optimized", %{
      person_quality_weight: gravitas_importance
    })
  end
  
  def predict_movie_success(movie_id) do
    gravitas = get_movie_gravitas(movie_id)
    other_metrics = get_movie_metrics(movie_id)
    
    features = Nx.tensor([
      gravitas.total_gravitas_score,
      gravitas.director_pqs,
      other_metrics.genre_popularity,
      other_metrics.release_timing,
      other_metrics.budget_tier
    ])
    
    model = load_trained_model()
    prediction = Scholar.Linear.LinearRegression.predict(model, features)
    
    %{
      predicted_box_office: Nx.to_number(prediction[0]),
      predicted_rating: Nx.to_number(prediction[1]),
      confidence: calculate_confidence(features)
    }
  end
end
```

## How This Integrates with Our Unified System

### 1. **It's Just Another Metric Category**
Person quality becomes another category like "rating" or "award":
```elixir
%{
  rating_weight: 0.25,
  award_weight: 0.25,
  financial_weight: 0.20,
  cultural_weight: 0.15,
  person_quality_weight: 0.15  # NEW!
}
```

### 2. **Uses Same Normalization Pipeline**
All PQS components go through our normalization:
```elixir
Registry.normalize_value("director_festival_wins", 5) # → 0.8
Registry.normalize_value("actor_versatility", 7) # → 0.7
```

### 3. **Appears in Same Search Interface**
```elixir
# Find movies with strong creative teams
Registry.search_movies(%{
  filters: [
    {metric_code: "movie_gravitas_score", min_normalized: 0.8},
    {category: "rating", min_normalized: 0.7}
  ]
})

# Find hidden gems by unknown directors
Registry.search_movies(%{
  filters: [
    {metric_code: "director_pqs", max_normalized: 0.3},
    {category: "rating", min_normalized: 0.8}
  ]
})
```

### 4. **Benefits from All Infrastructure**
- **Cachex**: PQS scores cached for fast access
- **Broadway**: Calculate scores in parallel
- **TimescaleDB**: Track career trajectories over time
- **ML**: Learn optimal weights for gravitas
- **Dashboard**: Visualize person quality metrics

## Implementation Additions Needed

### 1. Database Changes
```sql
-- Add to our migration
ALTER TABLE metric_definitions 
ADD COLUMN requires_aggregation BOOLEAN DEFAULT false;

-- Mark person metrics as requiring aggregation
UPDATE metric_definitions 
SET requires_aggregation = true 
WHERE category = 'person_quality';
```

### 2. New GenServer for Aggregation
```elixir
defmodule Cinegraph.Metrics.AggregationServer do
  use GenServer
  
  # Handles complex multi-source calculations
  def calculate_aggregate_metric(metric_code, entity_id) do
    case metric_code do
      "movie_gravitas_score" -> 
        PersonMetrics.Calculator.calculate_movie_gravitas(entity_id)
      "director_pqs" ->
        PersonMetrics.Calculator.calculate_director_pqs(entity_id)
      _ ->
        {:error, :not_aggregate}
    end
  end
end
```

### 3. Update Weight Profile UI
Add person quality to the weight categories in dashboard:
```html
<div class="weight-row">
  <span>Person Quality (Gravitas):</span>
  <input type="range" min="0" max="1" step="0.05" 
         value={profile.person_quality_weight} />
</div>
```

## Performance Considerations

### Computation Complexity
- **Director PQS**: ~100ms per director (with caching)
- **Movie Gravitas**: ~500ms per movie (fresh calculation)
- **Full Recalculation**: ~6 hours for entire database

### Optimization Strategies
1. **Incremental Updates**: Only recalculate when person adds new film
2. **Batch Processing**: Use Oban Pro workflows for bulk updates
3. **Materialized Views**: Store pre-calculated aggregates
4. **Smart Invalidation**: Only invalidate affected scores

## Benefits of Integration

1. **Unified Interface**: Person quality appears alongside all other metrics
2. **ML Optimization**: Learn if users actually care about "gravitas"
3. **A/B Testing**: Test if gravitas improves recommendations
4. **Cross-Metric Correlation**: See how gravitas relates to success
5. **Reusable Infrastructure**: All caching, normalization, UI components work

## Timeline Addition

Add to Phase 6 of main implementation (Weeks 8-10):

### Phase 6: Person Quality Metrics
- [ ] Create person quality database tables
- [ ] Implement PQS calculation pipeline
- [ ] Add gravitas score calculator
- [ ] Integrate with unified dashboard
- [ ] Set up caching strategy
- [ ] Add to search filters
- [ ] Train ML model for importance

## Conclusion

Person-based quality metrics fit **perfectly** into our unified system as an advanced "aggregate metric category". It leverages all the infrastructure we're building while adding sophisticated filmmaker reputation scoring. The key insight is that it's just another normalized metric that can be weighted, cached, and optimized like any other - it just requires more computation to generate.