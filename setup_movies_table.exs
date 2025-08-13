# Script to create movies table directly
# Run with: mix run setup_movies_table.exs

alias Cinegraph.Repo

# Create movies table
Repo.query!("""
CREATE TABLE IF NOT EXISTS movies (
  id BIGSERIAL PRIMARY KEY,
  tmdb_id INTEGER,
  imdb_id VARCHAR(255),
  title VARCHAR(255) NOT NULL,
  original_title VARCHAR(255),
  release_date DATE,
  runtime INTEGER,
  overview TEXT,
  tagline TEXT,
  original_language VARCHAR(10),
  status VARCHAR(50),
  adult BOOLEAN DEFAULT FALSE,
  homepage TEXT,
  origin_country TEXT[],
  poster_path VARCHAR(255),
  backdrop_path VARCHAR(255),
  collection_id INTEGER,
  tmdb_data JSONB,
  omdb_data JSONB,
  import_status VARCHAR(50),
  canonical_sources JSONB,
  inserted_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
)
""")

IO.puts "Created movies table"

# Create indexes
Repo.query!("CREATE INDEX IF NOT EXISTS idx_movies_tmdb_id ON movies(tmdb_id)")
Repo.query!("CREATE INDEX IF NOT EXISTS idx_movies_imdb_id ON movies(imdb_id)")
Repo.query!("CREATE INDEX IF NOT EXISTS idx_movies_title ON movies(title)")

IO.puts "Created indexes"