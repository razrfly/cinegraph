# TMDB Missing Data Action Plan

## Priority 1: Store Individual List Appearances (Biggest Gap!)

Currently we only store list count. We should store WHICH lists using our empty `movie_user_list_appearances` table:

```elixir
# In process_movie_lists - CURRENT (just counting)
list_count = length(lists)

# SHOULD BE:
Enum.each(lists, fn list ->
  # Store each list appearance
  UserList.create_or_update(%{
    tmdb_id: list["id"],
    name: list["name"],
    creator: list["created_by"]["username"],
    item_count: list["item_count"],
    list_type: list["list_type"]
  })
  
  # Link movie to list
  MovieUserListAppearance.create(%{
    movie_id: movie.id,
    list_id: user_list.id,
    discovered_at: DateTime.utc_now()
  })
end)
```

This gives us:
- Track which specific lists (AFI 100? Someone's "Best Gangster Films"?)
- List quality metrics (300 item list vs 5 item list)
- List evolution over time

## Priority 2: Implement Trending Tracking

Use our empty `external_trending` table:

```elixir
# Daily job to fetch and store
def fetch_daily_trending do
  {:ok, trending} = TMDb.get_trending("movie", "day")
  
  Enum.with_index(trending["results"], 1) 
  |> Enum.each(fn {movie_data, position} ->
    movie = Movies.get_or_create_by_tmdb_id(movie_data["id"])
    
    ExternalTrending.create(%{
      movie_id: movie.id,
      source_id: tmdb_source.id,
      trending_type: "daily",
      position: position,
      score: movie_data["popularity"],
      recorded_at: DateTime.utc_now()
    })
  end)
end
```

## Priority 3: Track Top Rated/Popular Positions

```elixir
# Store as external ratings
def fetch_list_positions do
  # Top Rated position
  {:ok, top_rated} = TMDb.get_top_rated()
  store_position_data(top_rated["results"], "top_rated_position")
  
  # Popular position  
  {:ok, popular} = TMDb.get_popular()
  store_position_data(popular["results"], "popular_position")
end
```

## What This Gives Us For CRI Scoring:

1. **List Authority Scoring**:
   - Movies on many lists = broad appeal
   - Movies on curated lists (high item count, descriptive) = critical appeal
   - List creator reputation (do they make many quality lists?)

2. **Trending Momentum**:
   - How often does it trend?
   - How high does it peak?
   - Trending longevity

3. **Sustained Excellence**:
   - How long in Top Rated?
   - Popular vs Top Rated delta
   - Platform prestige availability

## Implementation Order:

1. **Day 1**: Implement list appearance storage (biggest bang for buck)
2. **Day 2**: Add daily trending job
3. **Day 3**: Add position tracking for popular/top rated
4. **Day 4**: Parse watch provider data for platform prestige

## What We DON'T Need from TMDB:
- Individual review content (aggregate is enough)
- Translations (not relevant for cultural scoring)
- Alternative titles (unless checking festival names)
- Full user details (just need list creator info)