# Cultural Relevance Index (CRI) - Backtesting System

## Executive Summary

A focused metrics system designed specifically to derive weights that replicate the "1001 Movies Before You Die" list through ML-powered backtesting. This is the "Goldilocks" solution - more capable than the MVP, simpler than the full system, laser-focused on the CRI goal.

## Primary Goal

**Create a Cultural Relevance Index that achieves >80% overlap with the 1001 Movies list by discovering optimal metric weights through backtesting.**

## System Architecture (4 Tables + ML)

### Database Schema

```sql
-- 1. METRIC DEFINITIONS (Registry)
CREATE TABLE metric_definitions (
  code TEXT PRIMARY KEY,              -- 'imdb_rating', 'criterion_collection'
  name TEXT NOT NULL,
  category TEXT NOT NULL,             -- Maps to CRI dimensions
  cri_dimension TEXT NOT NULL,        -- 'timelessness','cultural_penetration','artistic_impact','institutional','public'
  data_type TEXT NOT NULL,
  normalization JSONB NOT NULL,
  source_reliability FLOAT DEFAULT 0.8,
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMP DEFAULT NOW()
);

-- 2. METRICS (Current values per movie)
CREATE TABLE metrics (
  movie_id BIGINT NOT NULL REFERENCES movies(id),
  metric_code TEXT NOT NULL REFERENCES metric_definitions(code),
  raw_value_numeric DOUBLE PRECISION,
  raw_value_text TEXT,
  normalized_value DOUBLE PRECISION NOT NULL,
  observed_at TIMESTAMPTZ,
  collected_at TIMESTAMPTZ DEFAULT NOW(),
  source_ref TEXT,
  PRIMARY KEY (movie_id, metric_code)
);

-- 3. WEIGHT PROFILES (Multiple configurations for testing)
CREATE TABLE weight_profiles (
  id SERIAL PRIMARY KEY,
  name TEXT UNIQUE NOT NULL,          -- 'cri_v1', 'cri_ml_optimized', 'cri_manual'
  description TEXT,
  profile_type TEXT NOT NULL,         -- 'manual', 'ml_derived', 'hybrid'
  
  -- CRI Dimension weights (must sum to 1.0)
  timelessness_weight FLOAT DEFAULT 0.2,
  cultural_penetration_weight FLOAT DEFAULT 0.2,
  artistic_impact_weight FLOAT DEFAULT 0.2,
  institutional_weight FLOAT DEFAULT 0.2,
  public_weight FLOAT DEFAULT 0.2,
  
  -- Per-metric weights (JSONB for flexibility)
  metric_weights JSONB NOT NULL DEFAULT '{}',
  
  -- Backtesting results
  backtest_score FLOAT,               -- % overlap with 1001 movies
  precision_score FLOAT,               -- Of our top 1001, how many are in the list
  recall_score FLOAT,                  -- Of the 1001 list, how many did we find
  f1_score FLOAT,                      -- Harmonic mean of precision/recall
  
  -- ML metadata
  training_method TEXT,                -- 'gradient_descent', 'genetic_algorithm', 'manual'
  training_iterations INTEGER,
  training_date TIMESTAMP,
  training_params JSONB,
  
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

-- 4. CRI SCORES (Computed results with profile reference)
CREATE TABLE cri_scores (
  movie_id BIGINT NOT NULL REFERENCES movies(id),
  profile_id INTEGER NOT NULL REFERENCES weight_profiles(id),
  
  -- Dimension scores
  timelessness_score FLOAT,
  cultural_penetration_score FLOAT,
  artistic_impact_score FLOAT,
  institutional_score FLOAT,
  public_score FLOAT,
  
  -- Final CRI
  total_cri_score FLOAT NOT NULL,
  percentile_rank FLOAT,              -- Where this movie ranks (0-100)
  
  -- For analysis
  is_in_1001_list BOOLEAN,            -- Ground truth
  predicted_in_1001 BOOLEAN,          -- Our prediction
  
  computed_at TIMESTAMP DEFAULT NOW(),
  explain JSONB,                      -- Feature contributions
  PRIMARY KEY (movie_id, profile_id)
);

-- Indexes for performance
CREATE INDEX idx_metrics_movie ON metrics(movie_id);
CREATE INDEX idx_cri_scores_profile ON cri_scores(profile_id);
CREATE INDEX idx_cri_scores_total ON cri_scores(total_cri_score DESC);
CREATE INDEX idx_cri_scores_1001 ON cri_scores(is_in_1001_list) WHERE is_in_1001_list = true;
```

## CRI Dimension Mapping

### 1. Timelessness (Enduring Relevance)
```elixir
[
  # How well it ages
  "imdb_rating",           # Consistent over time
  "letterboxd_rating",     # Modern reassessment
  "criterion_collection",  # Curated for preservation
  "nfr_preserved",         # National Film Registry
  "restoration_count"      # How often it's restored
]
```

### 2. Cultural Penetration (Pop Culture Impact)
```elixir
[
  "imdb_votes",           # Broad awareness
  "tmdb_popularity",      # Current interest
  "wikipedia_views",      # Research/reference
  "meme_references",      # Internet culture
  "parody_count",         # Cultural saturation
  "merchandise_sales"     # Commercial cultural impact
]
```

### 3. Artistic Impact (Influence on Cinema)
```elixir
[
  "sight_sound_rank",     # Critical consensus
  "afi_top_100",          # Industry recognition
  "director_retrospectives", # Studied filmmakers
  "film_school_curriculum", # Educational importance
  "technical_innovations", # Pioneering techniques
  "homage_count"          # Referenced by other films
]
```

### 4. Institutional Recognition
```elixir
[
  "oscar_wins",           # Academy recognition
  "oscar_nominations",    
  "cannes_awards",        # Festival prestige
  "venice_awards",
  "berlin_awards",
  "guild_awards",         # DGA, WGA, SAG
  "museum_exhibitions"    # MoMA, BFI, etc.
]
```

### 5. Public Reception
```elixir
[
  "rt_audience_score",    # General audience
  "metacritic_user",      # Engaged viewers
  "box_office_adjusted",  # Commercial success (inflation adjusted)
  "home_video_sales",     # Rewatchability
  "streaming_plays",      # Modern consumption
  "social_sentiment"      # Twitter/Reddit sentiment
]
```

## ML-Powered Backtesting System

### Weight Optimization with Scholar

```elixir
defmodule Cinegraph.CRI.WeightOptimizer do
  @moduledoc """
  Uses ML to find weights that best replicate the 1001 Movies list
  """
  
  import Nx.Defn
  alias Scholar.Metrics.Classification
  
  @doc """
  Main optimization function using gradient descent
  Goal: Find weights that maximize F1 score against 1001 Movies list
  """
  def optimize_weights_for_1001_movies do
    # Get ground truth
    ground_truth = get_1001_movies_list()
    all_movies = Repo.all(Movie)
    
    # Initialize random weights
    initial_weights = initialize_weights()
    
    # Training loop
    final_weights = 
      Enum.reduce(1..1000, initial_weights, fn iteration, current_weights ->
        # Apply weights and calculate scores
        scores = calculate_cri_scores(all_movies, current_weights)
        
        # Get top 1001 by our scoring
        our_top_1001 = 
          scores
          |> Enum.sort_by(& &1.total_cri_score, :desc)
          |> Enum.take(1001)
          |> MapSet.new(& &1.movie_id)
        
        # Calculate metrics
        true_positives = MapSet.intersection(our_top_1001, ground_truth) |> MapSet.size()
        false_positives = MapSet.difference(our_top_1001, ground_truth) |> MapSet.size()
        false_negatives = MapSet.difference(ground_truth, our_top_1001) |> MapSet.size()
        
        precision = true_positives / (true_positives + false_positives)
        recall = true_positives / (true_positives + false_negatives)
        f1 = 2 * (precision * recall) / (precision + recall)
        
        # Log progress
        if rem(iteration, 50) == 0 do
          Logger.info("Iteration #{iteration}: F1 = #{Float.round(f1, 3)}")
        end
        
        # Gradient descent step
        gradient = calculate_gradient(current_weights, scores, ground_truth)
        learning_rate = 0.01 * (0.99 ^ iteration) # Decay learning rate
        
        # Update weights
        update_weights(current_weights, gradient, learning_rate)
      end)
    
    # Save optimized profile
    save_weight_profile(final_weights, "cri_ml_optimized")
  end
  
  @doc """
  Alternative: Genetic Algorithm approach
  Better for non-differentiable objectives
  """
  def optimize_with_genetic_algorithm do
    population_size = 100
    generations = 500
    
    # Create initial population
    population = Enum.map(1..population_size, fn _ -> 
      random_weight_profile()
    end)
    
    # Evolution loop
    final_population = 
      Enum.reduce(1..generations, population, fn generation, current_pop ->
        # Evaluate fitness (F1 score) for each individual
        scored_pop = 
          current_pop
          |> Enum.map(fn weights ->
            f1 = evaluate_weights_against_1001(weights)
            {weights, f1}
          end)
          |> Enum.sort_by(fn {_, f1} -> f1 end, :desc)
        
        # Log best performer
        {best_weights, best_f1} = hd(scored_pop)
        if rem(generation, 20) == 0 do
          Logger.info("Generation #{generation}: Best F1 = #{Float.round(best_f1, 3)}")
        end
        
        # Selection (top 20%)
        survivors = 
          scored_pop
          |> Enum.take(div(population_size, 5))
          |> Enum.map(fn {weights, _} -> weights end)
        
        # Crossover and mutation
        new_generation = 
          survivors ++
          Enum.map(1..(population_size - length(survivors)), fn _ ->
            parent1 = Enum.random(survivors)
            parent2 = Enum.random(survivors)
            
            child = crossover(parent1, parent2)
            mutate(child, mutation_rate: 0.1)
          end)
        
        new_generation
      end)
    
    # Return best from final generation
    best = 
      final_population
      |> Enum.map(fn w -> {w, evaluate_weights_against_1001(w)} end)
      |> Enum.max_by(fn {_, f1} -> f1 end)
    
    {weights, f1_score} = best
    save_weight_profile(weights, "cri_genetic_optimized", f1_score)
  end
  
  defp calculate_gradient(weights, scores, ground_truth) do
    # Numerical gradient calculation
    epsilon = 0.001
    
    Map.new(weights, fn {key, value} ->
      # Perturb weight slightly
      weights_plus = Map.put(weights, key, value + epsilon)
      weights_minus = Map.put(weights, key, value - epsilon)
      
      # Calculate F1 for both
      f1_plus = evaluate_weights_against_1001(weights_plus)
      f1_minus = evaluate_weights_against_1001(weights_minus)
      
      # Gradient approximation
      gradient = (f1_plus - f1_minus) / (2 * epsilon)
      
      {key, gradient}
    end)
  end
  
  defp crossover(parent1, parent2) do
    # Uniform crossover
    Map.merge(parent1, parent2, fn _key, v1, v2 ->
      if :rand.uniform() > 0.5, do: v1, else: v2
    end)
    |> normalize_weights()
  end
  
  defp mutate(weights, mutation_rate: rate) do
    Map.new(weights, fn {key, value} ->
      if :rand.uniform() < rate do
        # Add Gaussian noise
        noise = :rand.normal() * 0.1
        {key, max(0, value + noise)}
      else
        {key, value}
      end
    end)
    |> normalize_weights()
  end
end
```

### Backtesting Dashboard

```elixir
defmodule CinegraphWeb.CRIBacktestLive do
  use CinegraphWeb, :live_view
  
  def render(assigns) do
    ~H"""
    <div class="cri-backtest-dashboard">
      <!-- Weight Profiles Comparison -->
      <div class="profiles-comparison">
        <h2>Weight Profiles Performance</h2>
        <table>
          <thead>
            <tr>
              <th>Profile</th>
              <th>Type</th>
              <th>F1 Score</th>
              <th>Precision</th>
              <th>Recall</th>
              <th>Overlap</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for profile <- @profiles do %>
              <tr class={if profile.id == @selected_profile_id, do: "selected"}>
                <td><%= profile.name %></td>
                <td>
                  <span class="badge badge-<%= profile.profile_type %>">
                    <%= profile.profile_type %>
                  </span>
                </td>
                <td>
                  <strong><%= format_percent(profile.f1_score) %></strong>
                </td>
                <td><%= format_percent(profile.precision_score) %></td>
                <td><%= format_percent(profile.recall_score) %></td>
                <td>
                  <div class="overlap-bar">
                    <div class="bar" style={"width: #{profile.backtest_score}%"}></div>
                  </div>
                  <%= format_percent(profile.backtest_score) %>
                </td>
                <td>
                  <button phx-click="select_profile" phx-value-id={profile.id}>
                    View
                  </button>
                  <button phx-click="run_backtest" phx-value-id={profile.id}>
                    Re-test
                  </button>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
      
      <!-- Confusion Matrix -->
      <div class="confusion-matrix">
        <h3>1001 Movies Prediction Results</h3>
        <div class="matrix-grid">
          <div class="cell header"></div>
          <div class="cell header">Predicted IN</div>
          <div class="cell header">Predicted OUT</div>
          
          <div class="cell header">Actually IN</div>
          <div class="cell true-positive">
            <strong><%= @confusion.true_positives %></strong>
            <small>Correctly found</small>
          </div>
          <div class="cell false-negative">
            <strong><%= @confusion.false_negatives %></strong>
            <small>Missed</small>
          </div>
          
          <div class="cell header">Actually OUT</div>
          <div class="cell false-positive">
            <strong><%= @confusion.false_positives %></strong>
            <small>Wrong inclusion</small>
          </div>
          <div class="cell true-negative">
            <strong><%= @confusion.true_negatives %></strong>
            <small>Correctly excluded</small>
          </div>
        </div>
      </div>
      
      <!-- Weight Visualization -->
      <%= if @selected_profile do %>
        <div class="weight-details">
          <h3>Weight Configuration: <%= @selected_profile.name %></h3>
          
          <!-- Dimension Weights -->
          <div class="dimension-weights">
            <h4>CRI Dimensions</h4>
            <div class="weight-bars">
              <div class="weight-row">
                <label>Timelessness</label>
                <div class="bar-container">
                  <div class="bar" style={"width: #{@selected_profile.timelessness_weight * 100}%"}>
                    <%= Float.round(@selected_profile.timelessness_weight, 2) %>
                  </div>
                </div>
              </div>
              <div class="weight-row">
                <label>Cultural Penetration</label>
                <div class="bar-container">
                  <div class="bar" style={"width: #{@selected_profile.cultural_penetration_weight * 100}%"}>
                    <%= Float.round(@selected_profile.cultural_penetration_weight, 2) %>
                  </div>
                </div>
              </div>
              <!-- etc for other dimensions -->
            </div>
          </div>
          
          <!-- Top Contributing Metrics -->
          <div class="metric-importance">
            <h4>Most Important Metrics</h4>
            <table>
              <%= for {metric, weight} <- top_metrics(@selected_profile.metric_weights) do %>
                <tr>
                  <td><%= metric %></td>
                  <td>
                    <div class="importance-bar">
                      <div class="bar" style={"width: #{weight * 100}%"}></div>
                    </div>
                  </td>
                  <td><%= Float.round(weight, 3) %></td>
                </tr>
              <% end %>
            </table>
          </div>
        </div>
      <% end %>
      
      <!-- Missing & Found Analysis -->
      <div class="analysis-grid">
        <div class="missing-movies">
          <h3>Movies We Missed</h3>
          <p class="subtitle">In 1001 list but not our top 1001</p>
          <ul>
            <%= for movie <- @missing_movies do %>
              <li>
                <%= movie.title %> (<%= movie.year %>)
                <small>CRI: <%= Float.round(movie.cri_score, 2) %> | Rank: #<%= movie.rank %></small>
              </li>
            <% end %>
          </ul>
        </div>
        
        <div class="false-positives">
          <h3>Our Additions</h3>
          <p class="subtitle">In our top 1001 but not the list</p>
          <ul>
            <%= for movie <- @false_positives do %>
              <li>
                <%= movie.title %> (<%= movie.year %>)
                <small>CRI: <%= Float.round(movie.cri_score, 2) %></small>
              </li>
            <% end %>
          </ul>
        </div>
      </div>
      
      <!-- Optimization Controls -->
      <div class="optimization-panel">
        <h3>Weight Optimization</h3>
        
        <div class="optimization-methods">
          <button phx-click="optimize_gradient" class="btn-primary">
            <.icon name="hero-beaker" /> Gradient Descent
          </button>
          
          <button phx-click="optimize_genetic" class="btn-primary">
            <.icon name="hero-sparkles" /> Genetic Algorithm
          </button>
          
          <button phx-click="manual_tune" class="btn-secondary">
            <.icon name="hero-adjustments-horizontal" /> Manual Tuning
          </button>
        </div>
        
        <%= if @optimization_running do %>
          <div class="optimization-progress">
            <div class="progress-bar">
              <div class="bar" style={"width: #{@optimization_progress}%"}></div>
            </div>
            <p>
              Iteration <%= @current_iteration %> / <%= @total_iterations %>
              | Best F1: <%= Float.round(@best_f1, 3) %>
            </p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
  
  def handle_event("optimize_gradient", _, socket) do
    # Start async optimization
    Task.start(fn ->
      Cinegraph.CRI.WeightOptimizer.optimize_weights_for_1001_movies()
      send(self(), :optimization_complete)
    end)
    
    {:noreply, assign(socket, optimization_running: true, current_iteration: 0)}
  end
  
  def handle_info({:optimization_progress, iteration, f1}, socket) do
    {:noreply, assign(socket,
      current_iteration: iteration,
      best_f1: max(socket.assigns.best_f1, f1),
      optimization_progress: iteration / socket.assigns.total_iterations * 100
    )}
  end
end
```

## Implementation Plan (2-3 Weeks)

### Week 1: Core System
1. **Day 1-2**: Create 4 tables, Ecto schemas
2. **Day 3**: Build metric adapters (TMDb, IMDb, festivals, lists)
3. **Day 4**: Implement normalization
4. **Day 5**: Basic CRI scoring

### Week 2: Backtesting
1. **Day 6-7**: Import 1001 Movies list as ground truth
2. **Day 8**: Build backtesting framework
3. **Day 9**: Create confusion matrix analysis
4. **Day 10**: Dashboard for results

### Week 3: ML Optimization
1. **Day 11-12**: Implement gradient descent optimizer
2. **Day 13**: Add genetic algorithm option
3. **Day 14**: Fine-tuning UI
4. **Day 15**: Documentation & testing

## Key Differences from MVP and Full System

### What We Keep from MVP
- Simple schema (just 4 tables)
- JSON-based configs
- Fast implementation

### What We Add Beyond MVP
- Weight profiles table (store multiple configs)
- Backtest scoring in profiles
- ML optimization capabilities
- CRI-specific dimensions

### What We Skip from Full System
- No time-series/history
- No user personalization
- No real-time updates
- No complex caching
- No person quality metrics (yet)

## Success Metrics

### Primary Goal
- **>80% overlap** with 1001 Movies list
- **>0.75 F1 score** in classification

### Secondary Goals
- Identify 50+ "missed classics" not in 1001
- Achieve <100ms scoring time per movie
- Generate explainable weights

### Validation
- Test on other canonical lists (AFI, Sight & Sound)
- Year-based validation (works across decades)
- Genre balance (not biased to specific genres)

## Migration Path

### To Add Later (Without Breaking)
1. **Person Quality**: Add as new metrics/dimension
2. **Time-Series**: Add metric_history table
3. **User Profiles**: Add user_id to weight_profiles
4. **Advanced ML**: Integrate Axon for neural networks

## Why This Approach Works

1. **Focused Goal**: Specifically designed to solve the CRI/1001 Movies problem
2. **Right-Sized**: More than MVP (has ML), less than full (no unnecessary features)
3. **Testable**: Built-in backtesting from day one
4. **Explainable**: Can show why weights work
5. **Extensible**: Can grow into full system later

## Conclusion

This "Goldilocks" solution gives you:
- Working CRI in 2-3 weeks
- ML-powered weight optimization
- Clear success metrics (F1 score)
- Direct path to >80% overlap goal
- Foundation for future expansion

Start here, achieve the 1001 Movies goal, then expand based on what you learn.