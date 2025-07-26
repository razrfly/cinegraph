# Configuration for movie import process
import Config

config :cinegraph, :import,
  # Default number of pages to import (20 movies per page)
  default_pages: 10,
  
  # TMDB settings
  tmdb_concurrency: 1,  # Will be increased when we add parallel processing
  tmdb_delay_ms: 100,   # Delay between TMDB requests
  
  # OMDB settings (free tier limits)
  omdb_delay_ms: 1000,  # 1 second between requests
  omdb_daily_limit: 1000,
  
  # Retry settings
  max_retry_attempts: 3,
  retry_delay_ms: 2000,
  
  # Progress tracking
  show_progress: true,
  progress_update_interval: 10,  # Update progress every N movies
  
  # Post-import processing
  calculate_cri_scores: false,  # Will be enabled later
  populate_cultural_lists: false  # Will be enabled later

# Development settings
if Mix.env() == :dev do
  config :cinegraph, :import,
    default_pages: 5,
    show_progress: true
end

# Test settings
if Mix.env() == :test do
  config :cinegraph, :import,
    default_pages: 1,
    omdb_delay_ms: 0,
    tmdb_delay_ms: 0
end