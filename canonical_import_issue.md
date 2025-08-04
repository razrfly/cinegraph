# GitHub Issue: Fix Canonical Movie Import to Match Oscar Import Pattern

## Problem

The canonical movie import system (for lists like "1001 Movies You Must See Before You Die") is not following our established import patterns, causing timeouts and preventing proper movie creation.

## Current Behavior

- ❌ Scraper fetches ALL 6 pages (1,260 movies) during parsing phase
- ❌ Attempts to process all movies synchronously (causes timeouts)
- ❌ No Oban jobs created for missing movies
- ❌ Not using TMDbDetailsWorker for movie creation
- ✅ First 250 movies are marked correctly (when it doesn't timeout)

## Expected Behavior

Should work like Oscar import:
1. Fetch data (one page at a time or async)
2. For each movie:
   - If exists: Update with canonical metadata
   - If missing: Queue TMDbDetailsWorker job
3. TMDbDetailsWorker creates movie and marks as canonical

## Root Cause

```elixir
# Current (WRONG):
CanonicalImporter.import_1001_movies()
  → ImdbCanonicalScraper.scrape_and_parse_list()  # Fetches ALL pages!
  → Processes 1,260 movies synchronously
  → Timeout!

# Should be (like Oscar):
CanonicalImporter.import_1001_movies()
  → Process page by page
  → Queue TMDbDetailsWorker for missing movies
  → Async processing via Oban
```

## Solution

### 1. Fix Scraper

```elixir
# Add single page fetch
def fetch_single_page(list_id, page \\ 1) do
  url = build_imdb_list_url(list_id, page)
  with {:ok, html} <- fetch_html(url),
       {:ok, movies} <- parse_imdb_list_html(html) do
    {:ok, movies}
  end
end
```

### 2. Fix Importer to Match Oscar Pattern

```elixir
defp process_canonical_movie(movie_data, source_key, metadata) do
  case Repo.get_by(Movie, imdb_id: movie_data.imdb_id) do
    nil ->
      # Queue for creation (like Oscar does)
      TMDbDetailsWorker.new(%{
        "imdb_id" => movie_data.imdb_id,
        "source" => "canonical_import",
        "canonical_source" => %{
          "source_key" => source_key,
          "metadata" => metadata
        }
      })
      |> Oban.insert()
      
    existing_movie ->
      # Update directly
      Movies.update_canonical_sources(existing_movie, source_key, metadata)
  end
end
```

### 3. Use Existing Post-Processing

TMDbDetailsWorker already has canonical marking support:

```elixir
# In TMDbDetailsWorker.handle_post_creation_tasks/2
args["source"] == "canonical_import" && args["canonical_source"] ->
  mark_movie_canonical(tmdb_id, source_key, metadata)
```

## Tasks

- [ ] Separate `fetch_single_page` from `scrape_and_parse_list`
- [ ] Implement page-by-page processing in importer
- [ ] Use TMDbDetailsWorker for missing movies
- [ ] Add progress tracking
- [ ] Create mix task like `import_oscars`
- [ ] Test with full 1,260 movie import

## Benefits

- No more timeouts
- Consistent with existing patterns
- Reuses battle-tested code
- Progress monitoring via Oban
- Can handle any size list

## Test Plan

1. Import single page (250 movies)
2. Verify Oban jobs created for missing movies
3. Verify existing movies updated
4. Import all pages without timeout
5. Check canonical marking works via TMDbDetailsWorker