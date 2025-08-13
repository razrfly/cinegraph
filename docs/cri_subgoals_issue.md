# Replace Discovery System & Enable Unified Search with CRI Architecture

## Overview

While the primary goal of the CRI (Cultural Relevance Index) system is to replicate the "1001 Movies Before You Die" list through ML optimization, the same architecture provides a complete solution for several critical sub-goals that will modernize Cinegraph's entire metrics and discovery infrastructure.

## Sub-Goals This System Achieves

### 1. 🔄 Replace Hardcoded Discovery Scoring System

**Current Problem:**
```elixir
# Current: Inflexible hardcoded weights in discovery_scoring.ex
def calculate_score(movie) do
  popular_opinion = movie.imdb_rating * 0.3 + movie.tmdb_rating * 0.3
  critical_acclaim = movie.metacritic_score * 0.4 + movie.rt_tomatometer * 0.6
  # ... more hardcoded logic
end
```

**CRI Solution:**
```elixir
# New: Dynamic weight profiles with infinite flexibility
profile = WeightProfile.get("discovery_default")
score = CRI.calculate_score(movie_id, profile)

# Can have multiple discovery strategies:
- discovery_crowd_pleaser
- discovery_critics_choice  
- discovery_hidden_gems
- discovery_ml_optimized
- discovery_trending_now
```

**Benefits:**
- A/B test different discovery strategies
- Personalize per user segment
- Adjust weights without code changes
- ML can optimize discovery for engagement

### 2. 🔍 Enable General Cross-Source Search

**Current Problem:**
- Can't search "highly rated movies" across all rating sources
- Can't search "award-winning films" across all festivals
- Different scales make comparison impossible (IMDb 0-10 vs Metacritic 0-100)

**CRI Solution:**
```elixir
# Search across ALL rating sources with normalization
CRI.search(%{
  category: "rating",
  min_normalized: 0.8  # Works across IMDb, TMDb, Metacritic, RT
})

# Search across ALL award sources
CRI.search(%{
  cri_dimension: "institutional",  # All festivals/awards
  min_normalized: 0.6
})

# Complex multi-criteria search
CRI.search(%{
  filters: [
    {category: "rating", min_normalized: 0.7},
    {category: "award", min_normalized: 0.5},
    {metric_code: "tmdb_popularity", max_normalized: 0.3}  # Hidden gems
  ]
})
```

**Benefits:**
- Universal search across all data sources
- Fair comparison through normalization
- Combine multiple criteria easily
- Works for both general and specific searches

### 3. 🎯 Maintain Specific Search Capabilities

**Current Problem:**
- Users still need to search "Metacritic > 80" specifically
- Some searches need exact values, not normalized

**CRI Solution:**
```elixir
# Specific searches still work perfectly
CRI.search(%{
  metric_code: "metacritic_score",
  min_raw_value: 80  # Uses raw value, not normalized
})

# Boolean searches
CRI.search(%{
  metric_code: "criterion_collection",
  raw_value_text: "true"
})

# Ranking searches
CRI.search(%{
  metric_code: "afi_top_100",
  max_raw_value: 50  # Top 50 of AFI's list
})
```

**Benefits:**
- Best of both worlds: general AND specific
- Raw values preserved alongside normalized
- Backwards compatible with existing searches

### 4. 📊 Provide Complete Metrics Dashboard

**Current Problem:**
- No visibility into what data we have
- Can't see coverage gaps
- No way to manage weights visually

**CRI Solution:**
- **Metrics Registry View**: See all 29+ data sources
- **Coverage Dashboard**: Identify data gaps instantly
- **Weight Manager**: Adjust profiles with sliders
- **Test Playground**: Preview scoring changes in real-time

### 5. 🤖 Enable ML-Driven Optimization

**Current Problem:**
- No way to optimize weights based on user behavior
- Can't learn what combinations work best
- Manual weight adjustment is guesswork

**CRI Solution:**
```elixir
# Optimize for user engagement
WeightOptimizer.optimize_from_engagement(user_interactions)

# Optimize for specific goals
WeightOptimizer.optimize_for_goal("maximize_session_time")
WeightOptimizer.optimize_for_goal("increase_watchlist_adds")

# Discover user segments
clusters = WeightOptimizer.discover_user_segments()
# Creates profiles like "critics", "blockbuster_fans", "indie_lovers"
```

### 6. 👤 Future: User Personalization

**Current Problem:**
- One-size-fits-all discovery
- No personal preference learning

**CRI Solution (Built-in Capability):**
```elixir
# Each user can have personalized weights
user_profile = WeightProfile.for_user(user_id)

# Learn from user behavior
WeightOptimizer.personalize_for_user(user_id, interaction_history)

# Collaborative filtering built on same infrastructure
similar_users = CRI.find_users_with_similar_weights(user_id)
```

## Implementation Priority

### Phase 1: Core Infrastructure (Week 1)
✅ Already designed in Issue #260
- 4-table schema
- Metric definitions with normalization
- Weight profiles system
- Basic CRI scoring

### Phase 2: Discovery Replacement (Week 2)
- Migrate current discovery scoring to weight profile
- Create multiple discovery strategies
- A/B testing framework
- LiveView UI for weight management

### Phase 3: Search Enhancement (Week 2-3)
- General search across categories
- Specific metric searches
- Combined filter searches
- Search UI updates

### Phase 4: ML Optimization (Week 3-4)
- Implement gradient descent optimizer
- User behavior tracking
- Engagement-based learning
- Segment discovery

## Success Metrics

### Discovery Replacement
- [ ] All discovery scoring uses weight profiles
- [ ] Can switch strategies without code changes
- [ ] A/B tests show 10%+ engagement improvement
- [ ] Weight adjustments reflect instantly

### Search Enhancement
- [ ] "Highly rated" searches work across all sources
- [ ] "Award winners" searches work across all festivals
- [ ] Specific searches (Metacritic > 80) still work
- [ ] Search response time < 100ms

### Overall System
- [ ] 90%+ of movies have normalized metrics
- [ ] Dashboard used daily by team
- [ ] New data sources added in < 1 hour
- [ ] ML optimization shows measurable improvement

## Migration Path

### From Current Discovery Scoring
```elixir
# 1. Create legacy profile matching current weights
WeightProfile.create!(%{
  name: "legacy_discovery",
  timelessness_weight: 0.2,      # Maps to your cultural_impact
  cultural_penetration_weight: 0.3, # Maps to popular_opinion
  artistic_impact_weight: 0.3,    # Maps to critical_acclaim
  institutional_weight: 0.2,      # Maps to industry_recognition
  
  metric_weights: %{
    "imdb_rating" => 0.5,
    "tmdb_rating" => 0.5,
    # ... your current weights
  }
})

# 2. Update discovery module to use CRI
def calculate_score(movie_id) do
  # Old: complex hardcoded logic
  # New: one line
  CRI.calculate_score(movie_id, "legacy_discovery")
end

# 3. Create improved profiles
profiles = [
  "discovery_balanced",      # Equal weights
  "discovery_critics",       # High metacritic/festival
  "discovery_crowd",         # High IMDb/TMDb
  "discovery_hidden_gems",   # Low popularity, high quality
  "discovery_ml_optimized"   # ML-discovered optimal
]

# 4. A/B test to find best performer
```

### From Current Search
```elixir
# Current: Multiple separate queries
imdb_high = Repo.all(from m in Movie, where: m.imdb_rating > 8)
metacritic_high = Repo.all(from m in Movie, 
  join: em in ExternalMetric,
  where: em.value > 80 and em.source == "metacritic")

# New: Single unified query
highly_rated = CRI.search(%{
  category: "rating",
  min_normalized: 0.8
})
```

## Key Advantages

1. **One System, Multiple Goals**: CRI architecture solves primary goal (1001 Movies) AND all sub-goals
2. **Future-Proof**: Easy to add person quality, time-series, streaming data later
3. **Backwards Compatible**: Existing searches continue to work
4. **Performance**: Cached calculations, indexed queries
5. **Flexibility**: Infinite weight combinations without code changes
6. **Intelligence**: ML can optimize for any metric (engagement, revenue, retention)

## Conclusion

The CRI system isn't just about replicating the 1001 Movies list - it's a complete modernization of Cinegraph's metrics infrastructure that will:
- Replace inflexible hardcoded scoring
- Enable powerful cross-source searches
- Maintain specific search capabilities  
- Provide complete visibility and control
- Learn and improve through ML

This positions Cinegraph as a leader in intelligent movie discovery and recommendation.

## Related Issues
- #260: CRI Backtesting System (Primary implementation)
- #254: Original Unified Metrics proposal
- #256: ML Libraries research
- #259: MVP comparison