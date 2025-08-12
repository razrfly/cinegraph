# 1001 Movies Backtesting Plan - Comprehensive Assessment

## Executive Summary

The goal is to use the "1001 Movies You Must See Before You Die" list as a target variable to backtest and develop a predictive model that can identify movies likely to appear in future editions of the book (published every 5 years).

**Key Advantage**: We already have ALL 1,256 movies that have appeared across ALL editions of the book. This gives us the complete universe of movies the editors have considered worthy, which is invaluable for pattern recognition.

## Current Data Status

### ✅ What We Have

#### 1. Core Movie Data
- **Total Movies**: 5,521 in database
- **1001 Movies Collection**: 1,256 movies (ALL editions combined - every movie that has EVER appeared in any edition)
- **Data Quality**: 100% of these movies have basic TMDb data
- **Important**: This is the complete historical collection, not just one edition

#### 2. External Metrics Coverage (for 1001 Movies)
| Metric | Coverage | Avg Value | Source |
|--------|----------|-----------|--------|
| Rating Average | 100% (1256) | 7.4/10 | TMDb/IMDb |
| Rating Votes | 100% (1256) | 48,516 | TMDb/IMDb |
| Popularity Score | 100% (1256) | 12.81 | TMDb |
| Revenue Worldwide | 64% (806) | $109.7M | TMDb |
| Budget | 62% (780) | $17.9M | TMDb |
| Tomatometer | 55% (688) | 91.21% | Rotten Tomatoes |
| Awards Summary | 55% (685) | Text | OMDb |
| Metascore | 39% (484) | 82.6/100 | Metacritic |
| Revenue Domestic | 33% (416) | $30.2M | OMDb |

#### 3. Festival & Awards Data
- **Festival Organizations**: 7 major festivals configured
- **Festival Nominations**: 834 total nominations tracked
- **Oscar Data**: 2016-2024 available via scraping
- **Coverage Gap**: Limited overlap with 1001 movies (needs assessment)

#### 4. Cultural Lists
- Criterion Collection (configured)
- BFI Sight & Sound Top 100 (configured)
- National Film Registry (configured)
- **Status**: Import capability exists but data not yet imported

### ❌ Missing/Incomplete Data

#### 1. Edition-Specific Tracking
- **Critical Gap**: While we have ALL movies across all editions, we need to track WHICH movies appeared in WHICH editions:
  - Need edition metadata (which movies were in 2003, 2008, 2013, 2018, 2023 editions)
  - Track additions/removals between editions
  - Identify temporal patterns in selection criteria
  - This metadata is essential for training our prediction model

#### 2. Box Office Data
- Only 33% domestic revenue coverage
- Missing international breakdown by region
- No inflation-adjusted values
- No opening weekend performance

#### 3. Festival Coverage
- Limited historical festival data (only recent years)
- Missing major festivals: TIFF, Telluride, Locarno
- No regional/specialized festival data
- Incomplete winner/nominee distinction

#### 4. Critical Reception Timeline
- Static ratings (no temporal evolution)
- Missing initial vs. retrospective critical reception
- No critical consensus evolution tracking

#### 5. Cultural Impact Metrics
- No social media presence/mentions
- Missing streaming availability data
- No home video/physical media sales
- Absence of cultural reference tracking

## Statistical Approach for Prediction

### 1. Feature Engineering

#### Tier 1: Strong Predictors (High Correlation Expected)
- **Critical Acclaim Composite**: Weighted average of Metacritic, RT Critics, IMDb rating
- **Cultural Recognition**: Presence in other canonical lists (Criterion, BFI, NFR)
- **Festival Performance**: Major festival wins/nominations (Cannes, Venice, Berlin)
- **Temporal Relevance**: Years since release, anniversary alignments

#### Tier 2: Moderate Predictors
- **Commercial Success**: Box office performance relative to budget
- **Genre Representation**: Underrepresented genres in current edition
- **Geographic Diversity**: Country of origin vs. current edition distribution
- **Director Prestige**: Other films by director in the list

#### Tier 3: Contextual Factors
- **Streaming Availability**: Current accessibility
- **Recent Restoration**: New 4K releases, restorations
- **Cultural Moments**: Anniversaries, director retrospectives
- **Thematic Relevance**: Current social/political themes

### 2. Model Architecture

#### Phase 1: Historical Analysis
```python
# Pseudo-code for backtesting framework
def backtest_edition(train_editions, test_edition):
    # Train on previous editions
    features = extract_features(train_editions)
    model = train_model(features, labels)
    
    # Predict for test edition
    predictions = model.predict(test_edition_candidates)
    
    # Evaluate against actual additions
    precision = calculate_precision(predictions, actual_additions)
    recall = calculate_recall(predictions, actual_additions)
    
    return {
        'precision': precision,
        'recall': recall,
        'top_100_accuracy': top_k_accuracy(predictions, actual_additions, k=100)
    }
```

#### Phase 2: Ensemble Method
1. **Random Forest**: For non-linear feature interactions
2. **Gradient Boosting**: For complex patterns
3. **Neural Network**: For deep feature learning
4. **Weighted Voting**: Combine predictions with learned weights

#### Phase 3: Temporal Validation
- Train on editions 1-3, test on edition 4
- Train on editions 1-4, test on edition 5
- Use time-aware cross-validation

### 3. Weighting System Design

#### Dynamic Weight Calculation
```elixir
defmodule Cinegraph.Movies.PredictionWeights do
  @initial_weights %{
    critical_acclaim: 0.25,
    cultural_lists: 0.20,
    festival_awards: 0.15,
    box_office_performance: 0.10,
    temporal_factors: 0.10,
    genre_balance: 0.10,
    geographic_diversity: 0.10
  }
  
  def calculate_score(movie, weights \\ @initial_weights) do
    weights
    |> Enum.map(fn {factor, weight} ->
      score = calculate_factor_score(movie, factor)
      score * weight
    end)
    |> Enum.sum()
  end
  
  def optimize_weights(training_data) do
    # Use gradient descent or genetic algorithm
    # to find optimal weights based on historical data
  end
end
```

## Implementation Roadmap

### Phase 1: Data Completion (Week 1-2)
- [ ] Create edition tracking system (tag which movies belong to which editions)
- [ ] Research and map edition-specific membership for all 1,256 movies
- [ ] Import other canonical lists (Criterion, BFI, NFR)
- [ ] Fetch missing box office data from The Numbers API
- [ ] Expand festival data to 10-year history

### Phase 2: Feature Engineering (Week 2-3)
- [ ] Create composite metrics table
- [ ] Build temporal features
- [ ] Calculate cultural impact scores
- [ ] Generate director/actor prestige metrics

### Phase 3: Model Development (Week 3-4)
- [ ] Implement backtesting framework
- [ ] Train initial models
- [ ] Optimize hyperparameters
- [ ] Validate on historical editions

### Phase 4: Dashboard Creation (Week 4-5)
- [ ] Build prediction dashboard LiveView
- [ ] Create metric weighting interface
- [ ] Add backtesting visualization
- [ ] Implement real-time scoring updates

### Phase 5: Production System (Week 5-6)
- [ ] Deploy prediction API
- [ ] Set up monitoring and alerts
- [ ] Create batch prediction jobs
- [ ] Document methodology

## Dashboard Requirements

### 1. Data Source Overview
```elixir
defmodule CinegraphWeb.Live.BacktestDashboard do
  @sources [
    %{name: "TMDb", coverage: 100, weight: 0.15, status: :complete},
    %{name: "IMDb", coverage: 100, weight: 0.20, status: :complete},
    %{name: "Metacritic", coverage: 39, weight: 0.15, status: :partial},
    %{name: "Rotten Tomatoes", coverage: 55, weight: 0.15, status: :partial},
    %{name: "Box Office", coverage: 33, weight: 0.10, status: :incomplete},
    %{name: "Festivals", coverage: 15, weight: 0.15, status: :incomplete},
    %{name: "Cultural Lists", coverage: 0, weight: 0.10, status: :pending}
  ]
end
```

### 2. Key Metrics Display
- Overall data completeness percentage
- Prediction confidence score
- Backtesting accuracy metrics
- Feature importance visualization

### 3. Interactive Features
- Adjustable metric weights with real-time scoring
- Movie search with prediction scores
- Historical accuracy charts
- Export predictions to CSV

## Success Metrics

### Minimum Viable Prediction
- **Precision**: >60% for top 100 predictions
- **Recall**: >40% for all additions
- **Data Coverage**: >80% for all metrics

### Target Performance
- **Precision**: >75% for top 100 predictions
- **Recall**: >60% for all additions
- **Data Coverage**: >95% for critical metrics

### Statistical Validation
- Cross-validation score: >0.7 AUC
- Temporal stability: <10% variance across editions
- Feature importance stability: Top 5 features consistent

## Next Immediate Steps

1. **Import Historical Editions** (Priority 1)
   ```bash
   mix import_canonical --list 1001_movies_2018
   mix import_canonical --list 1001_movies_2013
   ```

2. **Create Prediction Module** (Priority 2)
   ```elixir
   defmodule Cinegraph.Movies.Prediction do
     # Core prediction logic
   end
   ```

3. **Build Dashboard LiveView** (Priority 3)
   ```elixir
   defmodule CinegraphWeb.Live.PredictionDashboard do
     # Dashboard implementation
   end
   ```

## Risk Assessment

### Data Risks
- Historical editions may be incomplete
- API rate limits for bulk data fetching
- Data quality inconsistencies across sources

### Model Risks
- Overfitting to historical patterns
- Editorial bias changes over time
- Regional representation shifts

### Mitigation Strategies
- Implement data quality checks
- Use ensemble methods to reduce overfitting
- Include confidence intervals in predictions
- Regular model retraining

## Conclusion

We have a solid foundation with:
- Complete collection of ALL 1,256 movies that have EVER appeared in any edition
- Good coverage of ratings and basic metrics for these movies
- Infrastructure for importing additional data

**We are approximately 50% ready** for backtesting. The critical missing pieces are:
1. Edition-specific metadata (which movies were in which editions) - this is ESSENTIAL for training
2. Expanded festival and awards data coverage
3. Complete box office information (only 33% coverage)
4. Other canonical lists for cross-validation

The good news is we already have the hardest part - all the movies and their basic metrics. With 3-4 weeks of focused development (less than originally estimated), we can:
- Map edition membership
- Expand data coverage to 80%+
- Build a robust prediction system with 70-75% accuracy for identifying future 1001 Movies additions