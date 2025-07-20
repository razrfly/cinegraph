# External Data Sources Implementation Guide

## Quick Start Examples

### 1. Setting Up Cultural Authorities

```elixir
# Create the Criterion Collection authority
criterion = %CulturalAuthority{
  slug: "criterion-collection",
  name: "The Criterion Collection",
  full_name: "The Criterion Collection Film Database",
  authority_type: "canonical",
  category: "official_list",
  subcategory: "curated_collection",
  base_weight: 0.9,
  trust_score: 10,
  prestige_score: 10,
  reach_score: 7,
  organization_name: "The Criterion Collection",
  country_code: "US",
  founded_year: 1984,
  website_url: "https://www.criterion.com",
  data_source_type: "scraper",
  update_frequency: "monthly"
}

# Create AFI authority
afi = %CulturalAuthority{
  slug: "afi-top-100",
  name: "AFI's 100 Years...100 Movies",
  authority_type: "canonical",
  category: "official_list",
  base_weight: 0.95,
  trust_score: 10,
  prestige_score: 10,
  reach_score: 9,
  organization_name: "American Film Institute",
  country_code: "US",
  founded_year: 1967,
  data_source_type: "manual",
  update_frequency: "static"
}

# Create Rotten Tomatoes authority
rt = %CulturalAuthority{
  slug: "rotten-tomatoes",
  name: "Rotten Tomatoes",
  authority_type: "critical",
  category: "critic_aggregate",
  base_weight: 0.7,
  trust_score: 8,
  prestige_score: 7,
  reach_score: 10,
  data_source_type: "api",
  update_frequency: "daily"
}

# Create TMDB User Lists authority
tmdb_users = %CulturalAuthority{
  slug: "tmdb-user-lists",
  name: "TMDB User Lists",
  authority_type: "crowdsourced",
  category: "user_list",
  base_weight: 0.3,  # Lower weight for crowdsourced
  trust_score: 5,
  prestige_score: 3,
  reach_score: 8,
  data_source_type: "api",
  update_frequency: "daily",
  requires_validation: true,
  validation_rules: %{
    min_follower_count: 10,
    min_item_count: 20,
    max_spam_score: 0.3
  }
}
```

### 2. Importing Official Lists

```elixir
# Import Criterion Collection titles
def import_criterion_collection(authority) do
  # Create the list
  list = %CuratedList{
    authority_id: authority.id,
    slug: "criterion-spine-numbers",
    name: "Criterion Collection Spine Numbers",
    list_type: "ranked",  # Ranked by spine number
    scope: "global",
    criteria: "Films selected for their artistic merit and cultural significance",
    total_items: 1200,  # Approximate
    verification_status: "verified"
  }
  
  # Import individual films
  criterion_films = fetch_criterion_data()
  
  Enum.each(criterion_films, fn film ->
    # Try to match with our movie database
    {movie_id, confidence} = match_movie(film.title, film.year, film.director)
    
    %ListItem{
      list_id: list.id,
      movie_id: movie_id,
      position: film.spine_number,
      original_title: film.title,
      original_year: film.year,
      original_director: film.director,
      match_confidence: confidence,
      match_method: if(confidence > 0.9, do: "exact", else: "fuzzy"),
      citation: film.description,
      metadata: %{
        spine_number: film.spine_number,
        release_date: film.criterion_release_date,
        special_features: film.special_features
      }
    }
    |> Repo.insert!()
  end)
end
```

### 3. Processing Awards Data

```elixir
# Import Academy Awards
def import_oscars(year) do
  ceremony = %AwardCeremony{
    authority_id: get_authority("academy-awards").id,
    name: "Academy Awards",
    year: year,
    edition_number: year - 1927,  # First Oscars in 1928 for 1927 films
    ceremony_date: ~D[2024-03-10],  # Example for 2024
    location: "Dolby Theatre, Hollywood"
  }
  
  # Create categories
  best_picture = %AwardCategory{
    ceremony_id: ceremony.id,
    name: "Best Picture",
    category_type: "film",
    display_order: 1
  }
  
  # Import nominations
  nominations = fetch_oscar_nominations(year, "Best Picture")
  
  Enum.each(nominations, fn nom ->
    movie_id = match_movie(nom.title, year - 1)  # Usually previous year's films
    
    %AwardNomination{
      category_id: best_picture.id,
      movie_id: movie_id,
      is_winner: nom.winner,
      original_movie_title: nom.title,
      match_confidence: 0.95
    }
    |> Repo.insert!()
  end)
end
```

### 4. Handling User-Generated Lists

```elixir
# Import and score TMDB user lists
def process_tmdb_user_list(list_data) do
  # First, get or create user profile
  user = %ExternalUserProfile{
    platform: "tmdb",
    external_user_id: list_data.created_by.id,
    username: list_data.created_by.username,
    trust_score: calculate_user_trust_score(list_data.created_by)
  }
  
  # Calculate list quality
  quality_score = calculate_list_quality(list_data)
  
  # Only import high-quality lists
  if quality_score > 0.6 do
    list = %UserGeneratedList{
      user_profile_id: user.id,
      platform: "tmdb",
      external_list_id: list_data.id,
      name: list_data.name,
      description: list_data.description,
      item_count: list_data.item_count,
      curation_score: quality_score,
      diversity_score: calculate_diversity(list_data.items),
      import_priority: quality_score * 100  # Higher quality = higher priority
    }
    
    # Import items
    import_list_items(list, list_data.items)
  end
end

defp calculate_list_quality(list_data) do
  factors = [
    {has_description?(list_data), 0.2},
    {unique_items_ratio(list_data), 0.3},
    {not_spam?(list_data), 0.3},
    {coherent_theme?(list_data), 0.2}
  ]
  
  Enum.reduce(factors, 0, fn {condition, weight}, acc ->
    if condition, do: acc + weight, else: acc
  end)
end
```

### 5. Social Media Integration

```elixir
# Track viral movie moments
def track_movie_meme(movie, meme_data) do
  %MemeReference{
    movie_id: movie.id,
    meme_name: meme_data.name,
    source_scene: meme_data.scene_description,
    original_quote: meme_data.quote,
    first_appearance: meme_data.first_seen,
    usage_count: fetch_usage_count(meme_data),
    platform_breakdown: %{
      "twitter" => meme_data.twitter_count,
      "reddit" => meme_data.reddit_count,
      "tiktok" => meme_data.tiktok_count
    },
    cultural_impact_score: calculate_meme_impact(meme_data)
  }
  |> Repo.insert!()
end

# Daily social metrics aggregation
def aggregate_daily_social_metrics(date) do
  movies_with_mentions = fetch_movies_mentioned_on(date)
  
  Enum.each(movies_with_mentions, fn movie ->
    mentions = fetch_mentions_for_movie(movie.id, date)
    
    %SocialMetricsSnapshot{
      movie_id: movie.id,
      snapshot_date: date,
      period_type: "daily",
      total_mentions: length(mentions),
      unique_authors: count_unique_authors(mentions),
      platform_breakdown: group_by_platform(mentions),
      average_sentiment: calculate_average_sentiment(mentions),
      is_trending: is_trending?(mentions),
      trend_triggers: detect_trend_triggers(mentions)
    }
    |> Repo.insert!()
  end)
end
```

### 6. Cultural References Tracking

```elixir
# Import academic citations
def import_academic_reference(movie, paper_data) do
  %CulturalReference{
    movie_id: movie.id,
    reference_type: "academic_paper",
    title: paper_data.title,
    context: paper_data.abstract_excerpt,
    source_type: "university",
    publication_date: paper_data.publication_date,
    author: paper_data.authors |> Enum.join(", "),
    doi: paper_data.doi,
    citation_count: paper_data.citation_count,
    journal_name: paper_data.journal,
    influence_score: calculate_academic_influence(paper_data)
  }
  |> Repo.insert!()
end

# Track museum exhibitions
def track_museum_exhibition(movie, exhibition_data) do
  %CulturalReference{
    movie_id: movie.id,
    authority_id: get_authority(exhibition_data.museum_slug).id,
    reference_type: "exhibition",
    title: exhibition_data.exhibition_name,
    description: exhibition_data.description,
    source_name: exhibition_data.museum_name,
    source_type: "museum",
    publication_date: exhibition_data.start_date,
    influence_score: 0.9,  # Museums are high prestige
    verified: true
  }
  |> Repo.insert!()
end
```

### 7. Calculating CRI Scores

```elixir
defmodule Cinegraph.CRI.Calculator do
  def calculate_cri_score(movie_id) do
    movie = Repo.get!(Movie, movie_id)
    
    # Gather all data sources
    components = %{
      canonical_lists: calculate_canonical_score(movie),
      awards: calculate_awards_score(movie),
      critical_reception: calculate_critical_score(movie),
      academic_presence: calculate_academic_score(movie),
      social_impact: calculate_social_score(movie),
      cultural_penetration: calculate_meme_score(movie),
      influence_graph: calculate_influence_score(movie),
      availability: calculate_availability_score(movie)
    }
    
    # Apply weights based on movie context
    weighted_score = apply_contextual_weights(components, movie)
    
    %CRIScore{
      movie_id: movie_id,
      score: weighted_score,
      components: components,
      version: "1.0",
      calculated_at: DateTime.utc_now()
    }
    |> Repo.insert!()
  end
  
  defp apply_contextual_weights(components, movie) do
    # Get weight adjustments for movie's context
    adjustments = Repo.all(
      from a in AuthorityWeightAdjustment,
      where: a.context_type == "decade" and a.context_value == ^movie_decade(movie)
    )
    
    # Apply adjustments to base weights
    # ... weight calculation logic
  end
end
```

### 8. Data Quality Management

```elixir
# Automated quality checks
def run_quality_checks do
  # Check for unmatched movies in lists
  unmatched_items = Repo.all(
    from li in ListItem,
    where: is_nil(li.movie_id),
    preload: [:list]
  )
  
  Enum.each(unmatched_items, fn item ->
    %DataQualityIssue{
      entity_type: "list_item",
      entity_id: item.id,
      issue_type: "missing_match",
      severity: "warning",
      description: "Movie '#{item.original_title}' (#{item.original_year}) not matched",
      suggested_action: "Manual review required",
      auto_fixable: false
    }
    |> Repo.insert!()
  end)
  
  # Check for suspicious user lists
  suspicious_lists = Repo.all(
    from ul in UserGeneratedList,
    where: ul.spam_score > 0.7 or ul.curation_score < 0.3
  )
  
  Enum.each(suspicious_lists, fn list ->
    %ContentModerationFlag{
      content_type: "user_list",
      content_id: list.id,
      flag_type: "low_quality",
      confidence: list.spam_score,
      flagged_by: "auto"
    }
    |> Repo.insert!()
  end)
end
```

### 9. Import Job Management

```elixir
defmodule Cinegraph.Import.JobRunner do
  use Oban.Worker
  
  @impl true
  def perform(%{args: %{"authority_id" => authority_id, "job_type" => job_type}}) do
    job = %ImportJob{
      authority_id: authority_id,
      job_type: job_type,
      status: "running",
      started_at: DateTime.utc_now()
    } |> Repo.insert!()
    
    try do
      result = case job_type do
        "full_sync" -> run_full_sync(authority_id)
        "incremental" -> run_incremental_sync(authority_id)
        _ -> {:error, "Unknown job type"}
      end
      
      job
      |> ImportJob.changeset(%{
        status: "completed",
        completed_at: DateTime.utc_now(),
        items_processed: result.processed,
        items_created: result.created,
        items_updated: result.updated
      })
      |> Repo.update!()
      
    rescue
      error ->
        job
        |> ImportJob.changeset(%{
          status: "failed",
          completed_at: DateTime.utc_now(),
          error_message: Exception.message(error),
          error_details: %{stacktrace: Exception.format_stacktrace()}
        })
        |> Repo.update!()
        
        reraise error, __STACKTRACE__
    end
  end
end
```

## Best Practices

1. **Always preserve original data** - Store unmodified source data for debugging and reprocessing
2. **Track confidence scores** - Every movie match should have a confidence score
3. **Implement gradual rollout** - Start with high-quality sources, expand gradually
4. **Monitor data quality** - Regular quality checks and moderation
5. **Version your algorithms** - Track which version calculated each score
6. **Plan for scale** - Use batch processing and background jobs
7. **Respect rate limits** - Implement proper throttling for external APIs
8. **Cache aggressively** - Social metrics don't need real-time updates