# Metrics Registry Schema Audit & UI Design

## Schema Compatibility Audit

### ✅ Current Schema Review

```sql
-- Core tables from issue #254
metric_definitions      -- Metric configurations
weight_profiles        -- Weight presets  
profile_metric_weights -- Specific weights per metric
metric_coverage_stats  -- Coverage tracking
```

### 🔍 Compatibility Analysis with Future Tools

#### 1. **Nx/Scholar (Machine Learning) - ✅ COMPATIBLE**

The schema works perfectly because:

```elixir
# Schema provides everything ML needs:
defmodule ML.Integration do
  # 1. Raw values from external_metrics table
  raw_data = Repo.all(from em in ExternalMetric)
  
  # 2. Normalization params from metric_definitions
  normalization = Repo.get_by(MetricDefinition, code: "tmdb_rating")
  
  # 3. Training features from normalized values
  features = Nx.tensor([
    [normalized_tmdb, normalized_imdb, normalized_metacritic],
    # ... more movies
  ])
  
  # 4. Store learned weights back to weight_profiles
  Repo.insert(%WeightProfile{
    name: "ml_optimized_#{user_id}",
    rating_weight: learned_weights[0],
    award_weight: learned_weights[1],
    # ...
  })
end
```

**Key Point**: The `profile_metric_weights` table is perfect for storing ML-discovered weights!

#### 2. **TimescaleDB (Time-Series) - ✅ COMPATIBLE**

Works seamlessly as an extension:

```sql
-- Our schema + TimescaleDB extension
CREATE TABLE metric_timeseries (
  movie_id INTEGER,
  metric_code VARCHAR(50) REFERENCES metric_definitions(code), -- Links!
  value FLOAT,
  normalized_value FLOAT,
  time TIMESTAMPTZ NOT NULL
);

-- The foreign key to metric_definitions ensures consistency!
```

#### 3. **Broadway (Data Pipeline) - ✅ COMPATIBLE**

Pipeline can read/write directly:

```elixir
def handle_batch(_, messages, _, _) do
  # 1. Lookup normalization rules
  definitions = Repo.all(MetricDefinition)
  
  # 2. Process messages using definitions
  normalized = Enum.map(messages, fn msg ->
    definition = Enum.find(definitions, & &1.code == msg.metric_code)
    normalize_using_definition(msg.value, definition)
  end)
  
  # 3. Update coverage stats
  Repo.insert(%MetricCoverageStat{...})
end
```

#### 4. **Cachex - ✅ COMPATIBLE**

Cache keys map directly to schema:

```elixir
# Cache key structure matches database relations
"metric_def:#{metric_code}"           # From metric_definitions
"weight_profile:#{profile_name}"      # From weight_profiles  
"coverage:#{metric_code}:#{date}"     # From metric_coverage_stats
```

#### 5. **PromEx/Telemetry - ✅ COMPATIBLE**

Metrics align with schema:

```elixir
:telemetry.execute(
  [:cinegraph, :metrics, :normalize],
  %{duration: duration},
  %{
    metric_code: metric_def.code,      # From metric_definitions
    category: metric_def.category,     # From metric_definitions
    profile_id: weight_profile.id      # From weight_profiles
  }
)
```

### ⚠️ Schema Improvements Needed

Based on the audit, here are recommended additions:

```sql
-- 1. Add version tracking for ML models
ALTER TABLE weight_profiles ADD COLUMN 
  ml_model_version VARCHAR(50),
  ml_model_accuracy FLOAT,
  training_date TIMESTAMP,
  training_sample_size INTEGER;

-- 2. Add caching hints
ALTER TABLE metric_definitions ADD COLUMN
  cache_ttl_seconds INTEGER DEFAULT 3600,
  is_cacheable BOOLEAN DEFAULT true;

-- 3. Add audit trail for weight changes
CREATE TABLE weight_profile_history (
  id SERIAL PRIMARY KEY,
  profile_id INTEGER REFERENCES weight_profiles(id),
  changed_by INTEGER REFERENCES users(id),
  changed_at TIMESTAMP NOT NULL DEFAULT NOW(),
  old_values JSONB,
  new_values JSONB,
  change_reason TEXT
);

-- 4. Add user feedback for ML training
CREATE TABLE metric_feedback (
  id SERIAL PRIMARY KEY,
  user_id INTEGER REFERENCES users(id),
  movie_id INTEGER REFERENCES movies(id),
  profile_id INTEGER REFERENCES weight_profiles(id),
  relevance_score FLOAT, -- Was this a good recommendation?
  created_at TIMESTAMP NOT NULL DEFAULT NOW()
);
```

## 📊 LiveView UI Design

### Main Dashboard (`/admin/metrics`)

```elixir
defmodule CinegraphWeb.Admin.MetricsRegistryLive do
  use CinegraphWeb, :live_view
  
  @impl true
  def render(assigns) do
    ~H"""
    <div class="metrics-registry-dashboard">
      <!-- Navigation Tabs -->
      <div class="tabs">
        <.link patch={~p"/admin/metrics/definitions"} 
               class={@live_action == :definitions && "active"}>
          Metric Definitions
        </.link>
        <.link patch={~p"/admin/metrics/weights"} 
               class={@live_action == :weights && "active"}>
          Weight Profiles
        </.link>
        <.link patch={~p"/admin/metrics/coverage"} 
               class={@live_action == :coverage && "active"}>
          Coverage Stats
        </.link>
        <.link patch={~p"/admin/metrics/playground"} 
               class={@live_action == :playground && "active"}>
          Test Playground
        </.link>
      </div>
      
      <!-- Dynamic Content Based on Tab -->
      <%= case @live_action do %>
        <% :definitions -> %>
          <.definitions_view {assigns} />
        <% :weights -> %>
          <.weights_view {assigns} />
        <% :coverage -> %>
          <.coverage_view {assigns} />
        <% :playground -> %>
          <.playground_view {assigns} />
      <% end %>
    </div>
    """
  end
end
```

### 1. Metric Definitions View

```elixir
def definitions_view(assigns) do
  ~H"""
  <div class="definitions-manager">
    <!-- Category Filter Pills -->
    <div class="category-filters">
      <button phx-click="filter_category" phx-value-category="all" 
              class={@category_filter == "all" && "active"}>
        All (<%= @metrics_count.all %>)
      </button>
      <button phx-click="filter_category" phx-value-category="rating"
              class={@category_filter == "rating" && "active"}>
        Ratings (<%= @metrics_count.rating %>)
      </button>
      <button phx-click="filter_category" phx-value-category="award"
              class={@category_filter == "award" && "active"}>
        Awards (<%= @metrics_count.award %>)
      </button>
      <button phx-click="filter_category" phx-value-category="financial"
              class={@category_filter == "financial" && "active"}>
        Financial (<%= @metrics_count.financial %>)
      </button>
      <button phx-click="filter_category" phx-value-category="cultural"
              class={@category_filter == "cultural" && "active"}>
        Cultural (<%= @metrics_count.cultural %>)
      </button>
    </div>
    
    <!-- Metrics Table -->
    <table class="metrics-table">
      <thead>
        <tr>
          <th>Code</th>
          <th>Name</th>
          <th>Source</th>
          <th>Raw Scale</th>
          <th>Normalization</th>
          <th>Reliability</th>
          <th>Coverage</th>
          <th>Actions</th>
        </tr>
      </thead>
      <tbody>
        <%= for metric <- @metrics do %>
          <tr>
            <td><code><%= metric.code %></code></td>
            <td><%= metric.name %></td>
            <td>
              <span class="badge badge-<%= metric.source %>">
                <%= metric.source %>
              </span>
            </td>
            <td>
              <%= if metric.raw_scale_min do %>
                <%= metric.raw_scale_min %>-<%= metric.raw_scale_max %>
                <%= metric.raw_unit %>
              <% else %>
                <span class="text-muted">Unbounded</span>
              <% end %>
            </td>
            <td>
              <span class="normalization-type">
                <%= metric.normalization_type %>
              </span>
              <button phx-click="show_normalization" 
                      phx-value-metric={metric.code}
                      class="btn-icon">
                <.icon name="hero-calculator" />
              </button>
            </td>
            <td>
              <div class="reliability-meter">
                <div class="reliability-bar" 
                     style={"width: #{metric.source_reliability * 100}%"}>
                </div>
                <span><%= Float.round(metric.source_reliability, 2) %></span>
              </div>
            </td>
            <td>
              <%= if coverage = @coverage_map[metric.code] do %>
                <div class="coverage-indicator">
                  <span class={coverage_class(coverage.percentage)}>
                    <%= Float.round(coverage.percentage, 1) %>%
                  </span>
                  <small>(<%= coverage.movies_with_data %>/<%= coverage.total_movies %>)</small>
                </div>
              <% else %>
                <span class="text-muted">No data</span>
              <% end %>
            </td>
            <td>
              <button phx-click="edit_metric" phx-value-id={metric.id}>
                Edit
              </button>
              <button phx-click="test_metric" phx-value-code={metric.code}>
                Test
              </button>
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
    
    <!-- Add New Metric Button -->
    <button phx-click="new_metric" class="btn-primary">
      <.icon name="hero-plus" /> Add Metric Definition
    </button>
  </div>
  
  <!-- Normalization Modal -->
  <%= if @show_normalization do %>
    <.modal id="normalization-modal">
      <h3>Normalization: <%= @selected_metric.name %></h3>
      
      <div class="normalization-demo">
        <div class="formula">
          <%= case @selected_metric.normalization_type do %>
            <% "linear" -> %>
              <code>normalized = (value - <%= @selected_metric.raw_scale_min %>) / 
                    (<%= @selected_metric.raw_scale_max %> - <%= @selected_metric.raw_scale_min %>)</code>
            <% "logarithmic" -> %>
              <code>normalized = log(value + 1) / log(<%= @selected_metric.normalization_params["threshold"] %> + 1)</code>
            <% "sigmoid" -> %>
              <code>normalized = 1 / (1 + exp(-<%= @selected_metric.normalization_params["k"] %> * 
                    (<%= @selected_metric.normalization_params["midpoint"] %> - value)))</code>
            <% _ -> %>
              <code>Custom normalization function</code>
          <% end %>
        </div>
        
        <!-- Interactive Test -->
        <div class="test-normalizer">
          <input type="number" 
                 phx-keyup="test_normalization" 
                 placeholder="Enter test value"
                 value={@test_value} />
          
          <%= if @test_value do %>
            <div class="result">
              <strong><%= @test_value %></strong> 
              <.icon name="hero-arrow-right" />
              <strong><%= Float.round(@normalized_value, 3) %></strong>
            </div>
          <% end %>
        </div>
        
        <!-- Visual Graph -->
        <div class="normalization-graph">
          <canvas id="norm-graph" phx-hook="NormalizationGraph" 
                  data-metric={Jason.encode!(@selected_metric)} />
        </div>
      </div>
    </.modal>
  <% end %>
  """
end
```

### 2. Weight Profiles View

```elixir
def weights_view(assigns) do
  ~H"""
  <div class="weights-manager">
    <!-- Profile Cards -->
    <div class="profile-grid">
      <%= for profile <- @profiles do %>
        <div class="profile-card" class={@selected_profile_id == profile.id && "selected"}>
          <div class="profile-header">
            <h3><%= profile.name %></h3>
            <%= if profile.is_default do %>
              <span class="badge badge-primary">Default</span>
            <% end %>
            <%= if profile.ml_model_version do %>
              <span class="badge badge-ml">ML <%= profile.ml_model_version %></span>
            <% end %>
          </div>
          
          <!-- Weight Distribution Pie Chart -->
          <div class="weight-chart">
            <canvas phx-hook="WeightPieChart" 
                    data-weights={Jason.encode!(%{
                      rating: profile.rating_weight,
                      award: profile.award_weight,
                      financial: profile.financial_weight,
                      cultural: profile.cultural_weight,
                      popularity: profile.popularity_weight
                    })} />
          </div>
          
          <!-- Weight Values -->
          <div class="weight-values">
            <div class="weight-row">
              <span>Ratings:</span>
              <strong><%= percent(profile.rating_weight) %></strong>
            </div>
            <div class="weight-row">
              <span>Awards:</span>
              <strong><%= percent(profile.award_weight) %></strong>
            </div>
            <div class="weight-row">
              <span>Financial:</span>
              <strong><%= percent(profile.financial_weight) %></strong>
            </div>
            <div class="weight-row">
              <span>Cultural:</span>
              <strong><%= percent(profile.cultural_weight) %></strong>
            </div>
            <div class="weight-row">
              <span>Popularity:</span>
              <strong><%= percent(profile.popularity_weight) %></strong>
            </div>
          </div>
          
          <!-- Actions -->
          <div class="profile-actions">
            <button phx-click="select_profile" phx-value-id={profile.id}>
              View Details
            </button>
            <%= unless profile.is_system do %>
              <button phx-click="edit_profile" phx-value-id={profile.id}>
                Edit
              </button>
            <% end %>
            <button phx-click="test_profile" phx-value-id={profile.id}>
              Test
            </button>
          </div>
        </div>
      <% end %>
      
      <!-- Add New Profile Card -->
      <div class="profile-card add-new" phx-click="new_profile">
        <.icon name="hero-plus-circle" class="large" />
        <span>Create New Profile</span>
      </div>
    </div>
    
    <!-- Detailed Metric Weights (when profile selected) -->
    <%= if @selected_profile do %>
      <div class="metric-weights-detail">
        <h3>Metric-Level Weights for "<%= @selected_profile.name %>"</h3>
        
        <table class="metric-weights-table">
          <thead>
            <tr>
              <th>Metric</th>
              <th>Category</th>
              <th>Weight within Category</th>
              <th>Effective Weight</th>
              <th>Enabled</th>
            </tr>
          </thead>
          <tbody>
            <%= for weight <- @metric_weights do %>
              <tr>
                <td><%= weight.metric.name %></td>
                <td><span class="badge"><%= weight.metric.category %></span></td>
                <td>
                  <input type="range" 
                         min="0" max="1" step="0.05"
                         value={weight.weight}
                         phx-change="update_metric_weight"
                         phx-value-profile-id={@selected_profile.id}
                         phx-value-metric-code={weight.metric_code} />
                  <span><%= Float.round(weight.weight, 2) %></span>
                </td>
                <td>
                  <strong><%= calculate_effective_weight(weight, @selected_profile) %></strong>
                </td>
                <td>
                  <input type="checkbox"
                         checked={weight.enabled}
                         phx-click="toggle_metric"
                         phx-value-profile-id={@selected_profile.id}
                         phx-value-metric-code={weight.metric_code} />
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    <% end %>
  </div>
  """
end
```

### 3. Coverage Stats View

```elixir
def coverage_view(assigns) do
  ~H"""
  <div class="coverage-dashboard">
    <!-- Overall Coverage Summary -->
    <div class="coverage-summary">
      <div class="stat-card">
        <h4>Overall Coverage</h4>
        <div class="big-number"><%= @overall_coverage %>%</div>
        <small>of <%= @total_movies %> movies have data</small>
      </div>
      
      <div class="stat-card">
        <h4>Data Sources</h4>
        <div class="big-number"><%= @active_sources %></div>
        <small>active sources</small>
      </div>
      
      <div class="stat-card">
        <h4>Last Updated</h4>
        <div class="big-number"><%= relative_time(@last_update) %></div>
        <button phx-click="refresh_coverage" class="btn-small">
          <.icon name="hero-arrow-path" /> Refresh
        </button>
      </div>
    </div>
    
    <!-- Coverage by Category -->
    <div class="category-coverage">
      <h3>Coverage by Category</h3>
      <div class="coverage-bars">
        <%= for {category, stats} <- @category_coverage do %>
          <div class="coverage-bar-row">
            <label><%= String.capitalize(category) %></label>
            <div class="progress-bar">
              <div class="progress-fill" 
                   style={"width: #{stats.percentage}%; background: #{coverage_color(stats.percentage)}"}>
              </div>
            </div>
            <span class="percentage"><%= Float.round(stats.percentage, 1) %>%</span>
            <small>(<%= stats.sources %> sources)</small>
          </div>
        <% end %>
      </div>
    </div>
    
    <!-- Coverage by Source -->
    <div class="source-coverage">
      <h3>Coverage by Data Source</h3>
      <table class="coverage-table">
        <thead>
          <tr>
            <th>Source</th>
            <th>Metrics</th>
            <th>Coverage</th>
            <th>Avg Value</th>
            <th>Last Update</th>
            <th>Trend (7d)</th>
          </tr>
        </thead>
        <tbody>
          <%= for source <- @source_coverage do %>
            <tr>
              <td>
                <span class="source-badge badge-<%= source.name %>">
                  <%= String.upcase(source.name) %>
                </span>
              </td>
              <td><%= source.metric_count %></td>
              <td>
                <div class="mini-progress">
                  <div class="mini-fill" style={"width: #{source.coverage}%"}></div>
                </div>
                <%= Float.round(source.coverage, 1) %>%
              </td>
              <td><%= Float.round(source.avg_value || 0, 2) %></td>
              <td><%= relative_time(source.last_update) %></td>
              <td>
                <%= if source.trend > 0 do %>
                  <span class="trend-up">
                    <.icon name="hero-arrow-trending-up" />
                    +<%= Float.round(source.trend, 1) %>%
                  </span>
                <% else %>
                  <span class="trend-down">
                    <.icon name="hero-arrow-trending-down" />
                    <%= Float.round(source.trend, 1) %>%
                  </span>
                <% end %>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    
    <!-- Missing Data Analysis -->
    <div class="missing-data">
      <h3>Data Gaps Analysis</h3>
      <div class="gap-cards">
        <div class="gap-card">
          <h4>Movies with No Ratings</h4>
          <div class="count"><%= @gaps.no_ratings %></div>
          <button phx-click="show_movies" phx-value-filter="no_ratings">
            View Movies
          </button>
        </div>
        
        <div class="gap-card">
          <h4>Movies with No Awards Data</h4>
          <div class="count"><%= @gaps.no_awards %></div>
          <button phx-click="show_movies" phx-value-filter="no_awards">
            View Movies
          </button>
        </div>
        
        <div class="gap-card">
          <h4>Movies with No Financial Data</h4>
          <div class="count"><%= @gaps.no_financial %></div>
          <button phx-click="show_movies" phx-value-filter="no_financial">
            View Movies
          </button>
        </div>
      </div>
    </div>
  </div>
  """
end
```

### 4. Test Playground View

```elixir
def playground_view(assigns) do
  ~H"""
  <div class="metrics-playground">
    <h2>Test Metrics & Scoring</h2>
    
    <div class="playground-grid">
      <!-- Movie Selector -->
      <div class="movie-selector">
        <h3>Select Test Movie</h3>
        <input type="text" 
               phx-keyup="search_movies" 
               phx-debounce="300"
               placeholder="Search movies..." 
               value={@movie_search} />
        
        <%= if @search_results do %>
          <div class="search-results">
            <%= for movie <- @search_results do %>
              <div class="result-item" 
                   phx-click="select_movie" 
                   phx-value-id={movie.id}>
                <%= movie.title %> (<%= movie.year %>)
              </div>
            <% end %>
          </div>
        <% end %>
        
        <%= if @selected_movie do %>
          <div class="selected-movie">
            <h4><%= @selected_movie.title %></h4>
            <small><%= @selected_movie.year %></small>
          </div>
        <% end %>
      </div>
      
      <!-- Raw Metrics Display -->
      <div class="raw-metrics">
        <h3>Raw Metric Values</h3>
        <%= if @selected_movie do %>
          <table class="metrics-values">
            <%= for {category, metrics} <- group_metrics(@movie_metrics) do %>
              <tr class="category-header">
                <td colspan="3"><strong><%= String.capitalize(category) %></strong></td>
              </tr>
              <%= for metric <- metrics do %>
                <tr>
                  <td><%= metric.name %></td>
                  <td class="raw-value">
                    <%= format_raw_value(metric.value, metric.unit) %>
                  </td>
                  <td class="normalized-value">
                    → <%= Float.round(metric.normalized, 3) %>
                  </td>
                </tr>
              <% end %>
            <% end %>
          </table>
        <% else %>
          <p class="muted">Select a movie to see metrics</p>
        <% end %>
      </div>
      
      <!-- Weight Profile Tester -->
      <div class="weight-tester">
        <h3>Test Weight Profiles</h3>
        
        <select phx-change="select_test_profile">
          <option value="">Choose profile...</option>
          <%= for profile <- @profiles do %>
            <option value={profile.id}><%= profile.name %></option>
          <% end %>
        </select>
        
        <%= if @test_profile && @selected_movie do %>
          <div class="score-calculation">
            <h4>Score Calculation</h4>
            
            <!-- Category Scores -->
            <div class="category-scores">
              <%= for {category, score} <- @category_scores do %>
                <div class="score-row">
                  <span><%= String.capitalize(category) %>:</span>
                  <div class="score-bar">
                    <div class="score-fill" style={"width: #{score * 100}%"}>
                      <%= Float.round(score, 3) %>
                    </div>
                  </div>
                  <span class="weight">
                    × <%= Map.get(@test_profile, :"#{category}_weight") %>
                  </span>
                  <strong>= <%= Float.round(score * Map.get(@test_profile, :"#{category}_weight"), 3) %></strong>
                </div>
              <% end %>
            </div>
            
            <!-- Total Score -->
            <div class="total-score">
              <h3>Total Score: <span class="score-value"><%= Float.round(@total_score, 3) %></span></h3>
            </div>
          </div>
        <% end %>
      </div>
      
      <!-- A/B Comparison -->
      <div class="ab-comparison">
        <h3>Compare Profiles</h3>
        
        <div class="profile-selectors">
          <select phx-change="select_profile_a">
            <option value="">Profile A...</option>
            <%= for profile <- @profiles do %>
              <option value={profile.id}><%= profile.name %></option>
            <% end %>
          </select>
          
          <span>vs</span>
          
          <select phx-change="select_profile_b">
            <option value="">Profile B...</option>
            <%= for profile <- @profiles do %>
              <option value={profile.id}><%= profile.name %></option>
            <% end %>
          </select>
        </div>
        
        <%= if @profile_a && @profile_b && @selected_movie do %>
          <div class="comparison-results">
            <div class="profile-result">
              <h4><%= @profile_a.name %></h4>
              <div class="score"><%= Float.round(@score_a, 3) %></div>
            </div>
            
            <div class="difference">
              <%= if @score_a > @score_b do %>
                <span class="higher">+<%= Float.round(@score_a - @score_b, 3) %></span>
              <% else %>
                <span class="lower"><%= Float.round(@score_a - @score_b, 3) %></span>
              <% end %>
            </div>
            
            <div class="profile-result">
              <h4><%= @profile_b.name %></h4>
              <div class="score"><%= Float.round(@score_b, 3) %></div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
  </div>
  """
end
```

### JavaScript Hooks for Visualizations

```javascript
// app.js
Hooks.NormalizationGraph = {
  mounted() {
    const metric = JSON.parse(this.el.dataset.metric);
    this.drawGraph(metric);
  },
  
  drawGraph(metric) {
    const ctx = this.el.getContext('2d');
    // Draw normalization curve
    // Show how values from min to max map to 0-1
  }
};

Hooks.WeightPieChart = {
  mounted() {
    const weights = JSON.parse(this.el.dataset.weights);
    this.drawPieChart(weights);
  },
  
  drawPieChart(weights) {
    // Use Chart.js or similar to draw pie chart
  }
};
```

## 🎯 Key UI Features

1. **Visual Normalization Testing** - See exactly how values transform
2. **Real-time Weight Adjustment** - Sliders update scores instantly  
3. **Coverage Heatmaps** - Visual gaps in data
4. **A/B Testing Interface** - Compare profiles side-by-side
5. **ML Integration Indicators** - Shows which profiles are ML-optimized
6. **Audit Trail** - Track all changes to weights and definitions

## ✅ Schema Validation Summary

The proposed schema is **100% compatible** with all future tools:
- ✅ **Nx/Scholar** can read and write weights directly
- ✅ **TimescaleDB** extends the schema cleanly
- ✅ **Broadway** integrates seamlessly
- ✅ **Cachex** keys map to table structure
- ✅ **PromEx** metrics align with schema

The only additions needed are:
1. ML model versioning columns
2. Cache TTL hints
3. Audit trail table
4. User feedback table for training

The UI provides complete visibility and control over the entire metrics system!