# Cross-Project Movie Linking System for Eventasaurus Integration

## Overview
Implement a URL-based movie linking system to enable external projects (specifically [eventasaurus](https://github.com/razrfly/eventasaurus/issues/2414)) to link directly to Cinegraph movies using publicly available identifiers from TMDb, IMDb, or other movie databases.

## Problem Statement
Eventasaurus (film festival/event platform) needs to link to movies on Cinegraph without:
- Making API calls to Cinegraph
- Maintaining a database of Cinegraph's internal movie IDs
- Implementing complex slug generation logic
- Requiring authentication or API keys

They should be able to construct URLs using publicly available identifiers (TMDb ID, IMDb ID) that are universally accessible from major movie databases.

## User Story
```
AS an eventasaurus developer
I WANT to link to a Cinegraph movie page using just a TMDb or IMDb ID
SO THAT users can seamlessly navigate from events to detailed movie information
WITHOUT requiring API integration or complex URL construction logic
```

## Requirements

### Functional Requirements
1. ✅ **Zero API Calls**: Linking projects construct URLs without querying Cinegraph's API
2. ✅ **SEO-Friendly**: Maintain current slug-based canonical URLs for search engines
3. ✅ **Auto-Fetch**: If movie doesn't exist in Cinegraph DB, fetch from TMDb automatically
4. ✅ **Future-Proof**: Support multiple data sources (TMDb, IMDb, future: Letterboxd, Trakt)
5. ✅ **Backward Compatible**: Don't break existing `/movies/{slug}` URLs
6. ✅ **Performance**: <500ms for lookup + redirect

### Non-Functional Requirements
- Validate input to prevent injection attacks
- Rate limit auto-fetching to prevent abuse
- Log auto-fetch attempts for monitoring
- Track usage metrics by identifier type
- Handle errors gracefully with user-friendly messages

## Available Identifiers

### Currently Stored in Cinegraph Database
| Identifier | Database Field | Type | Indexed | Example | Coverage |
|------------|---------------|------|---------|---------|----------|
| TMDb ID | `movies.tmdb_id` | Integer | Unique | `550` | 100% |
| IMDb ID | `movies.imdb_id` | String | Yes | `tt0137523` | 99%+ |
| Slug | `movies.slug` | Custom | Unique | `fight-club-1999` | 100% |

### Available from TMDb API
- TMDb ID (always present)
- IMDb ID (99%+ of movies)
- Wikidata ID
- Facebook/Instagram/Twitter IDs (less useful for linking)

## Recommended Solution: Hybrid Multi-Source Routes

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    Cinegraph URL Entry Points                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  PRIMARY (Canonical SEO URL)                                     │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ GET /movies/{slug}                                        │   │
│  │ Example: /movies/fight-club-1999                         │   │
│  │ Status: ✅ Already implemented                            │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                   │
│  SECONDARY (Programmatic Access)                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ GET /movies/tmdb/{tmdb_id}                               │   │
│  │ Example: /movies/tmdb/550                                │   │
│  │ Behavior: Lookup → Auto-fetch if missing → Redirect      │   │
│  │ Target: Redirects to /movies/fight-club-1999             │   │
│  │ Status: 🔨 Needs implementation                          │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ GET /movies/imdb/{imdb_id}                               │   │
│  │ Example: /movies/imdb/tt0137523                          │   │
│  │ Behavior: Lookup → TMDb Find → Auto-fetch → Redirect    │   │
│  │ Target: Redirects to /movies/fight-club-1999             │   │
│  │ Status: 🔨 Needs implementation                          │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘

FLOW FOR TMDb ID ROUTE:
┌─────────────────────┐
│ User clicks link    │
│ /movies/tmdb/550    │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────────────────┐
│ Cinegraph Router                │
│ Matches: :tmdb_id param          │
└──────────┬──────────────────────┘
           │
           ▼
┌─────────────────────────────────┐
│ Movies.get_movie_by_tmdb_id/1   │
│ Query: WHERE tmdb_id = 550      │
└──────────┬──────────────────────┘
           │
           ├─ Found? ──────────────┐
           │                       │
           │                       ▼
           │              ┌─────────────────┐
           │              │ Redirect to     │
           │              │ /movies/{slug}  │
           │              └─────────────────┘
           │
           └─ Not Found? ─────────┐
                                  │
                                  ▼
                  ┌───────────────────────────────┐
                  │ TMDb.get_movie_details(550)   │
                  │ Fetch from TMDb API           │
                  └───────────┬───────────────────┘
                              │
                              ├─ Success? ─────────┐
                              │                    │
                              │                    ▼
                              │      ┌──────────────────────┐
                              │      │ Movies.create_movie  │
                              │      │ Store in database    │
                              │      └─────────┬────────────┘
                              │                │
                              │                ▼
                              │      ┌──────────────────────┐
                              │      │ Redirect to slug URL │
                              │      └──────────────────────┘
                              │
                              └─ Not Found? ──────┐
                                                   │
                                                   ▼
                                      ┌────────────────────┐
                                      │ 404 Error          │
                                      │ "Movie not found"  │
                                      └────────────────────┘
```

### Route Details

#### 1. Primary Route (Existing - No Changes)
```elixir
GET /movies/:id_or_slug
```
**Purpose**: Canonical SEO-friendly URLs
**Status**: ✅ Already implemented
**Example**: `/movies/fight-club-1999`
**Behavior**: Direct display of movie page

#### 2. TMDb ID Route (New - Recommended for Eventasaurus)
```elixir
GET /movies/tmdb/:tmdb_id
```
**Purpose**: Programmatic access via TMDb identifier
**Status**: 🔨 Needs implementation
**Example**: `/movies/tmdb/550`

**Behavior**:
1. Lookup movie by `tmdb_id` in local database
2. **If found**: Redirect to canonical slug URL (301 permanent redirect)
3. **If not found**:
   - Fetch movie details from TMDb API
   - Create movie record in database
   - Trigger background enrichment jobs (cast, crew, images)
   - Redirect to canonical slug URL
4. **If TMDb API fails**: Show 404 with helpful error message

**Why This Route?**
- ✅ Simplest for eventasaurus (no slug generation logic needed)
- ✅ TMDb ID is guaranteed to exist for all movies they have
- ✅ Numeric ID is compact and URL-safe
- ✅ Direct lookup with database index

#### 3. IMDb ID Route (New - Alternative Option)
```elixir
GET /movies/imdb/:imdb_id
```
**Purpose**: Cross-platform compatibility via IMDb identifier
**Status**: 🔨 Needs implementation
**Example**: `/movies/imdb/tt0137523`

**Behavior**:
1. Lookup movie by `imdb_id` in local database
2. **If found**: Redirect to canonical slug URL (301 permanent redirect)
3. **If not found**:
   - Use TMDb Find API to locate movie by IMDb ID
   - If found on TMDb: Fetch details and create movie record
   - Redirect to canonical slug URL
4. **If all lookups fail**: Show 404 with helpful error message

**Why This Route?**
- ✅ Industry-standard identifier
- ✅ More recognizable to users than TMDb ID
- ✅ Works across multiple platforms (IMDb, OMDb, TMDb)
- ⚠️ Requires additional API call (TMDb Find) if movie missing
- ⚠️ 1% of movies may lack IMDb ID

### Routing Decision Matrix

| Use Case | Recommended Route | Reasoning |
|----------|-------------------|-----------|
| **Programmatic linking** (eventasaurus) | `/movies/tmdb/{id}` | Simplest, most reliable, no slug logic |
| **User-friendly URLs** | `/movies/{slug}` | SEO, human-readable |
| **Cross-platform compatibility** | `/movies/imdb/{id}` | Works with IMDb, OMDb, TMDb |
| **Future: Letterboxd integration** | `/movies/letterboxd/{slug}` | Could be added later |

## Implementation Plan

### Phase 1: TMDb ID Route (Priority: HIGH)

**Estimated Effort**: 2-3 hours

#### 1.1 Router Changes
```elixir
# lib/cinegraph_web/router.ex
# Add after line 30 (after existing movie route)

live "/movies/tmdb/:tmdb_id", MovieLive.Show, :show_by_tmdb
```

#### 1.2 LiveView Handler
```elixir
# lib/cinegraph_web/live/movie_live/show.ex
# Add new handle_params clause

@impl true
def handle_params(%{"tmdb_id" => tmdb_id}, _url, socket) do
  with {tmdb_id, ""} <- Integer.parse(tmdb_id),
       {:ok, movie} <- fetch_or_create_movie_by_tmdb_id(tmdb_id) do
    {:noreply, redirect_to_canonical_url(socket, movie)}
  else
    {:error, :not_found} ->
      {:noreply,
       socket
       |> put_flash(:error, "Movie not found in TMDb database")
       |> push_navigate(to: ~p"/movies")}

    {:error, reason} ->
      {:noreply,
       socket
       |> put_flash(:error, "Error loading movie: #{reason}")
       |> push_navigate(to: ~p"/movies")}

    _ ->
      {:noreply,
       socket
       |> put_flash(:error, "Invalid TMDb ID")
       |> push_navigate(to: ~p"/movies")}
  end
end

defp fetch_or_create_movie_by_tmdb_id(tmdb_id) do
  case Movies.get_movie_by_tmdb_id(tmdb_id) do
    nil ->
      # Movie doesn't exist, fetch from TMDb
      fetch_and_create_from_tmdb(tmdb_id)

    movie ->
      {:ok, movie}
  end
end

defp fetch_and_create_from_tmdb(tmdb_id) do
  # Use existing comprehensive fetch logic
  case Movies.fetch_and_store_movie_comprehensive(tmdb_id) do
    {:ok, movie} ->
      # Log successful auto-fetch
      ApiTracker.track_lookup(
        source: "tmdb",
        operation: "auto_fetch_via_link",
        identifier: to_string(tmdb_id),
        success: true,
        metadata: %{
          movie_id: movie.id,
          created: true,
          triggered_by: "external_link"
        }
      )

      {:ok, movie}

    {:error, reason} ->
      # Log failed auto-fetch
      ApiTracker.track_lookup(
        source: "tmdb",
        operation: "auto_fetch_via_link",
        identifier: to_string(tmdb_id),
        success: false,
        error_message: to_string(reason)
      )

      {:error, reason}
  end
end

defp redirect_to_canonical_url(socket, movie) do
  socket
  |> put_flash(:info, "Viewing: #{movie.title}")
  |> push_navigate(to: ~p"/movies/#{movie.slug}")
end
```

#### 1.3 Context Function (if needed)
Check if `Movies.fetch_and_store_movie_comprehensive/1` exists. If not, create it:

```elixir
# lib/cinegraph/movies.ex

@doc """
Fetches a movie from TMDb by ID and stores it in the database with full details.
Triggers background jobs for enrichment (cast, crew, images, etc.).

## Examples

    iex> fetch_and_store_movie_comprehensive(550)
    {:ok, %Movie{tmdb_id: 550, title: "Fight Club"}}

    iex> fetch_and_store_movie_comprehensive(999999999)
    {:error, :not_found}
"""
def fetch_and_store_movie_comprehensive(tmdb_id) do
  # Fetch from TMDb API
  with {:ok, tmdb_data} <- TMDb.get_movie_details(tmdb_id),
       {:ok, movie} <- create_movie_from_tmdb_data(tmdb_data) do
    # Trigger background enrichment jobs
    enqueue_enrichment_jobs(movie)

    {:ok, movie}
  else
    {:error, :not_found} -> {:error, :not_found}
    {:error, reason} -> {:error, reason}
  end
end

defp create_movie_from_tmdb_data(tmdb_data) do
  # Use existing logic from import_movies task or create new
  # Transform TMDb API response into movie changeset and insert
  attrs = %{
    title: tmdb_data["title"],
    release_date: tmdb_data["release_date"],
    tmdb_id: tmdb_data["id"],
    imdb_id: tmdb_data["imdb_id"],
    overview: tmdb_data["overview"],
    runtime: tmdb_data["runtime"],
    status: tmdb_data["status"],
    budget: tmdb_data["budget"],
    revenue: tmdb_data["revenue"],
    poster_path: tmdb_data["poster_path"],
    backdrop_path: tmdb_data["backdrop_path"],
    original_language: tmdb_data["original_language"],
    original_title: tmdb_data["original_title"],
    # ... other fields
  }

  %Movie{}
  |> Movie.changeset(attrs)
  |> Repo.insert()
end

defp enqueue_enrichment_jobs(movie) do
  # Queue Oban jobs for:
  # - TMDbDetailsWorker (cast, crew, images)
  # - OMDbEnrichmentWorker (additional ratings)
  # - CollaborationBuilderWorker (relationship graphs)
  # etc.

  %{movie_id: movie.id}
  |> TMDbDetailsWorker.new()
  |> Oban.insert()

  :ok
end
```

### Phase 2: IMDb ID Route (Priority: MEDIUM)

**Estimated Effort**: 2-3 hours

#### 2.1 Router Changes
```elixir
# lib/cinegraph_web/router.ex
live "/movies/imdb/:imdb_id", MovieLive.Show, :show_by_imdb
```

#### 2.2 LiveView Handler
```elixir
# lib/cinegraph_web/live/movie_live/show.ex

@impl true
def handle_params(%{"imdb_id" => imdb_id}, _url, socket) do
  # Validate IMDb ID format
  unless valid_imdb_id?(imdb_id) do
    {:noreply,
     socket
     |> put_flash(:error, "Invalid IMDb ID format. Expected: tt0000000")
     |> push_navigate(to: ~p"/movies")}
  else
    with {:ok, movie} <- fetch_or_create_movie_by_imdb_id(imdb_id) do
      {:noreply, redirect_to_canonical_url(socket, movie)}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Movie not found: #{reason}")
         |> push_navigate(to: ~p"/movies")}
    end
  end
end

defp valid_imdb_id?(imdb_id) do
  # IMDb IDs: tt followed by 7-8 digits
  Regex.match?(~r/^tt\d{7,8}$/, imdb_id)
end

defp fetch_or_create_movie_by_imdb_id(imdb_id) do
  case Movies.get_movie_by_imdb_id(imdb_id) do
    nil ->
      # Movie doesn't exist, use TMDb Find API then fetch
      fetch_via_tmdb_find(imdb_id)

    movie ->
      {:ok, movie}
  end
end

defp fetch_via_tmdb_find(imdb_id) do
  # Use TMDb Find API to get TMDb ID from IMDb ID
  with {:ok, tmdb_id} <- TMDb.find_movie_by_imdb_id(imdb_id),
       {:ok, movie} <- Movies.fetch_and_store_movie_comprehensive(tmdb_id) do
    # Log successful auto-fetch via IMDb
    ApiTracker.track_lookup(
      source: "imdb",
      operation: "auto_fetch_via_imdb_link",
      identifier: imdb_id,
      success: true,
      metadata: %{
        movie_id: movie.id,
        tmdb_id: tmdb_id,
        created: true
      }
    )

    {:ok, movie}
  else
    {:error, reason} ->
      ApiTracker.track_lookup(
        source: "imdb",
        operation: "auto_fetch_via_imdb_link",
        identifier: imdb_id,
        success: false,
        error_message: to_string(reason)
      )

      {:error, reason}
  end
end
```

#### 2.3 TMDb Service Enhancement
```elixir
# lib/cinegraph/services/tmdb.ex

@doc """
Find TMDb movie ID using an external ID (IMDb, Wikidata, etc.)
Uses the TMDb /find/{external_id} API endpoint.

## Examples

    iex> TMDb.find_movie_by_imdb_id("tt0137523")
    {:ok, 550}

    iex> TMDb.find_movie_by_imdb_id("tt99999999")
    {:error, :not_found}
"""
def find_movie_by_imdb_id(imdb_id) do
  case Client.get("/find/#{imdb_id}", external_source: "imdb_id") do
    {:ok, %{"movie_results" => [%{"id" => tmdb_id} | _]}} ->
      {:ok, tmdb_id}

    {:ok, %{"movie_results" => []}} ->
      {:error, :not_found}

    {:error, reason} ->
      {:error, reason}
  end
end
```

### Phase 3: Testing & Documentation (Priority: HIGH)

**Estimated Effort**: 2-3 hours

#### 3.1 Update Router Documentation
```elixir
# lib/cinegraph_web/router.ex
# Add clear comments explaining the multi-source lookup system

# ========================================================================
# MOVIE VIEWING ROUTES
# ========================================================================
#
# Multiple entry points for viewing movies:
#
# 1. /movies/:slug (PRIMARY - SEO-friendly canonical URLs)
#    Example: /movies/fight-club-1999
#    Purpose: Direct display, optimized for search engines
#
# 2. /movies/tmdb/:tmdb_id (SECONDARY - Programmatic access)
#    Example: /movies/tmdb/550
#    Purpose: External project integration (eventasaurus, APIs)
#    Behavior: Lookup by TMDb ID → Auto-fetch if missing → Redirect to slug
#
# 3. /movies/imdb/:imdb_id (SECONDARY - Cross-platform compatibility)
#    Example: /movies/imdb/tt0137523
#    Purpose: Industry-standard IMDb ID linking
#    Behavior: Lookup by IMDb ID → TMDb Find → Auto-fetch → Redirect to slug
#
# All secondary routes redirect to the canonical slug URL to maintain SEO.
# ========================================================================

live "/movies/:id_or_slug", MovieLive.Show, :show
live "/movies/tmdb/:tmdb_id", MovieLive.Show, :show_by_tmdb
live "/movies/imdb/:imdb_id", MovieLive.Show, :show_by_imdb
```

#### 3.2 Comprehensive Tests
```elixir
# test/cinegraph_web/live/movie_live/show_test.exs

defmodule CinegraphWeb.MovieLive.ShowTest do
  use CinegraphWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  describe "show_by_tmdb/3" do
    test "redirects to canonical slug URL for existing movie", %{conn: conn} do
      movie = insert(:movie, tmdb_id: 550, slug: "fight-club-1999")

      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/movies/tmdb/550")

      assert path == ~p"/movies/#{movie.slug}"
    end

    test "fetches from TMDb and redirects for missing movie", %{conn: conn} do
      # Setup TMDb mock
      expect(TMDb.Mock, :get_movie_details, fn 550 ->
        {:ok,
         %{
           "id" => 550,
           "title" => "Fight Club",
           "release_date" => "1999-10-15",
           "imdb_id" => "tt0137523",
           "overview" => "A ticking-time-bomb insomniac...",
           "runtime" => 139,
           "status" => "Released",
           "poster_path" => "/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg"
         }}
      end)

      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/movies/tmdb/550")

      # Verify movie was created
      movie = Repo.get_by(Movie, tmdb_id: 550)
      assert movie
      assert movie.title == "Fight Club"
      assert movie.imdb_id == "tt0137523"

      # Verify redirect to slug
      assert path == ~p"/movies/#{movie.slug}"
    end

    test "shows error for invalid TMDb ID", %{conn: conn} do
      expect(TMDb.Mock, :get_movie_details, fn _ -> {:error, :not_found} end)

      {:error, {:redirect, %{to: path, flash: flash}}} =
        live(conn, ~p"/movies/tmdb/999999999")

      assert path == ~p"/movies"
      assert flash["error"] =~ "Movie not found"
    end

    test "shows error for non-numeric TMDb ID", %{conn: conn} do
      {:error, {:redirect, %{to: path, flash: flash}}} =
        live(conn, ~p"/movies/tmdb/abc123")

      assert path == ~p"/movies"
      assert flash["error"] =~ "Invalid TMDb ID"
    end

    test "logs auto-fetch attempt in api_lookup_metrics", %{conn: conn} do
      expect(TMDb.Mock, :get_movie_details, fn 550 ->
        {:ok,
         %{
           "id" => 550,
           "title" => "Fight Club",
           "release_date" => "1999-10-15"
         }}
      end)

      live(conn, ~p"/movies/tmdb/550")

      # Verify metric was recorded
      metric =
        Repo.get_by(ApiLookupMetric,
          source: "tmdb",
          operation: "auto_fetch_via_link"
        )

      assert metric
      assert metric.success == true
      assert metric.identifier == "550"
      assert metric.metadata["created"] == true
    end
  end

  describe "show_by_imdb/3" do
    test "redirects to canonical slug URL for existing movie", %{conn: conn} do
      movie = insert(:movie, imdb_id: "tt0137523", slug: "fight-club-1999")

      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/movies/imdb/tt0137523")

      assert path == ~p"/movies/#{movie.slug}"
    end

    test "finds via TMDb and redirects for missing movie", %{conn: conn} do
      # Mock TMDb Find API
      expect(TMDb.Mock, :find_movie_by_imdb_id, fn "tt0137523" -> {:ok, 550} end)

      # Mock TMDb Details API
      expect(TMDb.Mock, :get_movie_details, fn 550 ->
        {:ok,
         %{
           "id" => 550,
           "title" => "Fight Club",
           "imdb_id" => "tt0137523",
           "release_date" => "1999-10-15"
         }}
      end)

      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/movies/imdb/tt0137523")

      # Verify movie was created
      movie = Repo.get_by(Movie, imdb_id: "tt0137523")
      assert movie
      assert movie.tmdb_id == 550

      # Verify redirect
      assert path == ~p"/movies/#{movie.slug}"
    end

    test "shows error for invalid IMDb ID format", %{conn: conn} do
      {:error, {:redirect, %{to: path, flash: flash}}} =
        live(conn, ~p"/movies/imdb/invalid")

      assert path == ~p"/movies"
      assert flash["error"] =~ "Invalid IMDb ID format"
    end

    test "shows error when IMDb ID not found in TMDb", %{conn: conn} do
      expect(TMDb.Mock, :find_movie_by_imdb_id, fn _ -> {:error, :not_found} end)

      {:error, {:redirect, %{to: path, flash: flash}}} =
        live(conn, ~p"/movies/imdb/tt99999999")

      assert path == ~p"/movies"
      assert flash["error"] =~ "Movie not found"
    end
  end
end
```

#### 3.3 Integration Test
```elixir
# test/cinegraph_web/integration/external_linking_test.exs

defmodule CinegraphWeb.Integration.ExternalLinkingTest do
  use CinegraphWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  @moduletag :integration

  describe "eventasaurus linking flow" do
    test "can link to movie using TMDb ID from external project", %{conn: conn} do
      # Simulate eventasaurus constructing a URL
      tmdb_id = 550
      url = "https://cinegraph.app/movies/tmdb/#{tmdb_id}"

      # Mock TMDb API
      expect(TMDb.Mock, :get_movie_details, fn ^tmdb_id ->
        {:ok,
         %{
           "id" => tmdb_id,
           "title" => "Fight Club",
           "release_date" => "1999-10-15",
           "imdb_id" => "tt0137523"
         }}
      end)

      # User clicks link from eventasaurus
      {:error, {:redirect, %{to: canonical_path}}} = live(conn, url)

      # Verify redirect to SEO-friendly slug
      assert canonical_path =~ "/movies/fight-club-1999"

      # Verify movie exists in database
      movie = Repo.get_by(Movie, tmdb_id: tmdb_id)
      assert movie

      # Verify subsequent link clicks don't call API
      # (movie already exists)
      {:error, {:redirect, _}} = live(conn, url)

      # Should only have called API once
      assert_called_once(TMDb.Mock, :get_movie_details)
    end
  end
end
```

## Usage Documentation for Eventasaurus

### Quick Start Guide

#### Option 1: TMDb ID Route (Recommended)
This is the **simplest and most reliable** method:

```elixir
# In eventasaurus, when constructing a link to Cinegraph
def cinegraph_movie_url(movie) do
  "https://cinegraph.app/movies/tmdb/#{movie.tmdb_id}"
end
```

**Why this is recommended:**
- ✅ Requires zero logic (just insert TMDb ID)
- ✅ TMDb ID is guaranteed to exist for all movies
- ✅ Compact numeric ID
- ✅ Fast database lookup (indexed)

#### Option 2: IMDb ID Route (Alternative)
If you prefer using IMDb IDs:

```elixir
def cinegraph_movie_url(movie) do
  "https://cinegraph.app/movies/imdb/#{movie.imdb_id}"
end
```

**Trade-offs:**
- ✅ Industry-standard identifier
- ✅ More recognizable to users
- ⚠️ 1% of movies may lack IMDb ID
- ⚠️ Slightly slower (requires TMDb Find API if movie not cached)

#### Option 3: Slug Route (If you can generate slugs)
If you want to construct the slug yourself:

```elixir
def cinegraph_movie_url(movie) do
  # Slug format: "title-year"
  slug = "#{slugify(movie.title)}-#{extract_year(movie.release_date)}"
  "https://cinegraph.app/movies/#{slug}"
end

defp slugify(title) do
  title
  |> String.downcase()
  |> String.replace(~r/[^a-z0-9\s-]/, "")
  |> String.replace(~r/\s+/, "-")
  |> String.replace(~r/-+/, "-")
  |> String.trim("-")
end
```

**Trade-offs:**
- ✅ Most SEO-friendly URL
- ✅ No redirect needed
- ⚠️ Requires slug generation logic
- ⚠️ Must match Cinegraph's slug format exactly

### Complete Integration Example

```elixir
# In eventasaurus app
defmodule EventasaurusWeb.EventView do
  def movie_link(movie) do
    # Construct Cinegraph URL
    url = cinegraph_movie_url(movie)

    # Render link
    Phoenix.HTML.Link.link(
      movie.title,
      to: url,
      target: "_blank",
      rel: "noopener noreferrer",
      class: "text-blue-600 hover:underline"
    )
  end

  defp cinegraph_movie_url(movie) do
    base_url = Application.get_env(:eventasaurus, :cinegraph_url)
    "#{base_url}/movies/tmdb/#{movie.tmdb_id}"
  end
end
```

### Configuration

```elixir
# In eventasaurus config/config.exs
config :eventasaurus,
  cinegraph_url: "https://cinegraph.app"

# In eventasaurus config/dev.exs (for local testing)
config :eventasaurus,
  cinegraph_url: "http://localhost:4000"
```

## Security Considerations

### Input Validation
- ✅ Validate TMDb ID is integer (protect against SQL injection)
- ✅ Validate IMDb ID format (`^tt\d{7,8}$`)
- ✅ Sanitize error messages (don't expose internal details)
- ✅ Rate limit auto-fetching to prevent abuse

### Rate Limiting Strategy
```elixir
# In lib/cinegraph_web/plugs/rate_limiter.ex

defmodule CinegraphWeb.Plugs.AutoFetchRateLimiter do
  import Plug.Conn

  @max_auto_fetches_per_hour 100

  def init(opts), do: opts

  def call(conn, _opts) do
    # Use Hammer or similar for rate limiting
    case Hammer.check_rate("auto_fetch:#{get_ip(conn)}", 60_000, @max_auto_fetches_per_hour) do
      {:allow, _count} ->
        conn

      {:deny, _limit} ->
        conn
        |> put_flash(:error, "Too many requests. Please try again later.")
        |> Phoenix.Controller.redirect(to: "/movies")
        |> halt()
    end
  end

  defp get_ip(conn) do
    conn.remote_ip
    |> :inet.ntoa()
    |> to_string()
  end
end
```

Apply rate limiter to auto-fetch routes:
```elixir
# In router.ex
pipeline :auto_fetch_rate_limited do
  plug CinegraphWeb.Plugs.AutoFetchRateLimiter
end

scope "/movies", CinegraphWeb do
  pipe_through [:browser, :auto_fetch_rate_limited]

  live "/tmdb/:tmdb_id", MovieLive.Show, :show_by_tmdb
  live "/imdb/:imdb_id", MovieLive.Show, :show_by_imdb
end
```

### Logging & Monitoring
```elixir
# Track auto-fetch attempts
defp log_auto_fetch(source, identifier, result) do
  ApiTracker.track_lookup(
    source: source,
    operation: "auto_fetch_via_external_link",
    identifier: identifier,
    success: match?({:ok, _}, result),
    metadata: %{
      triggered_by: "external_link",
      referrer: get_referrer(socket),
      user_agent: get_user_agent(socket),
      ip_address: get_ip_address(socket)
    }
  )
end
```

## Monitoring & Metrics

### Key Metrics to Track

1. **Lookup Success Rates by Identifier Type**
```sql
SELECT
  source,
  operation,
  COUNT(*) FILTER (WHERE success = true) * 100.0 / COUNT(*) AS success_rate,
  COUNT(*) AS total_lookups
FROM api_lookup_metrics
WHERE operation IN ('auto_fetch_via_link', 'auto_fetch_via_imdb_link')
  AND inserted_at > NOW() - INTERVAL '7 days'
GROUP BY source, operation;
```

2. **Auto-Fetch Frequency & Costs**
```sql
SELECT
  DATE_TRUNC('day', inserted_at) AS date,
  COUNT(*) FILTER (WHERE metadata->>'created' = 'true') AS movies_auto_fetched,
  COUNT(*) FILTER (WHERE success = false) AS failed_auto_fetches,
  AVG(response_time_ms) AS avg_response_time_ms
FROM api_lookup_metrics
WHERE operation LIKE 'auto_fetch%'
  AND inserted_at > NOW() - INTERVAL '30 days'
GROUP BY date
ORDER BY date DESC;
```

3. **Most Frequently Auto-Fetched Movies**
```sql
-- Identify movies being discovered via external links
SELECT
  identifier,
  COUNT(*) AS fetch_count,
  MAX(inserted_at) AS last_fetched
FROM api_lookup_metrics
WHERE operation = 'auto_fetch_via_link'
  AND success = true
  AND metadata->>'created' = 'true'
GROUP BY identifier
HAVING COUNT(*) > 1  -- Fetched multiple times (caching issue?)
ORDER BY fetch_count DESC
LIMIT 20;
```

4. **Referrer Analysis (Where Links Are Coming From)**
```sql
SELECT
  metadata->>'referrer' AS referrer,
  COUNT(*) AS link_clicks,
  COUNT(*) FILTER (WHERE metadata->>'created' = 'true') AS new_movies_discovered
FROM api_lookup_metrics
WHERE operation LIKE 'auto_fetch%'
  AND inserted_at > NOW() - INTERVAL '30 days'
GROUP BY referrer
ORDER BY link_clicks DESC;
```

### Dashboard Visualization Ideas
- 📊 Daily auto-fetch volume chart
- 🎯 Success rate by identifier type (TMDb vs IMDb)
- 🌐 Geographic distribution of external referrers
- ⏱️ Average redirect time (lookup + redirect)
- 💰 Estimated TMDb API usage from auto-fetching
- 🔗 Top referring domains (eventasaurus.com, etc.)

## Future Enhancements

### Phase 4: Additional Data Sources (Optional)

#### Letterboxd Integration
```elixir
live "/movies/letterboxd/:letterboxd_slug", MovieLive.Show, :show_by_letterboxd
```

#### Trakt.tv Integration
```elixir
live "/movies/trakt/:trakt_slug", MovieLive.Show, :show_by_trakt
```

#### Universal Lookup Route (If We Add 3+ Sources)
```elixir
live "/movies/lookup/:source/:identifier", MovieLive.Show, :show_by_lookup
```

**Examples:**
- `/movies/lookup/tmdb/550`
- `/movies/lookup/imdb/tt0137523`
- `/movies/lookup/letterboxd/fight-club`
- `/movies/lookup/trakt/fight-club-1999`

**Implementation:**
```elixir
def handle_params(%{"source" => source, "identifier" => identifier}, _url, socket) do
  case lookup_by_source(source, identifier) do
    {:ok, movie} -> {:noreply, redirect_to_canonical_url(socket, movie)}
    {:error, reason} -> {:noreply, show_error(socket, reason)}
  end
end

defp lookup_by_source("tmdb", id), do: fetch_or_create_movie_by_tmdb_id(id)
defp lookup_by_source("imdb", id), do: fetch_or_create_movie_by_imdb_id(id)
defp lookup_by_source("letterboxd", slug), do: fetch_or_create_movie_by_letterboxd(slug)
defp lookup_by_source("trakt", slug), do: fetch_or_create_movie_by_trakt(slug)
defp lookup_by_source(_, _), do: {:error, :unsupported_source}
```

**Decision:** Defer until we have concrete use case for 3+ sources.

## Success Criteria

### Functional Success Criteria
- [ ] `/movies/tmdb/{tmdb_id}` route implemented and working
- [ ] `/movies/imdb/{imdb_id}` route implemented and working
- [ ] Auto-fetching creates movies from TMDb when missing
- [ ] All routes redirect to canonical slug URLs (SEO preserved)
- [ ] Error handling for invalid/missing IDs
- [ ] Input validation prevents injection attacks

### Quality Success Criteria
- [ ] Unit tests written and passing (>90% coverage)
- [ ] Integration tests verify end-to-end flow
- [ ] Documentation updated in router and LiveView
- [ ] Performance benchmarked (<500ms for lookup + redirect)
- [ ] Security review completed (validation, rate limiting)

### Integration Success Criteria
- [ ] Eventasaurus team notified of available endpoints
- [ ] Sample code provided for integration
- [ ] Monitoring dashboard shows usage metrics
- [ ] No errors reported in first week of production use

### Performance Criteria
- [ ] Average redirect time <500ms (existing movies)
- [ ] Average auto-fetch + redirect time <2s (missing movies)
- [ ] Rate limiting prevents abuse (max 100/hour per IP)
- [ ] Database queries use existing indexes (no slow queries)

## Risks & Mitigation

| Risk | Impact | Likelihood | Mitigation |
|------|--------|----------|------------|
| TMDb API abuse | High | Low | Rate limiting, monitoring, IP blocking |
| SEO degradation | High | Low | 301 redirects preserve link equity |
| Database bloat from spam | Medium | Medium | Validation, rate limiting, cleanup jobs |
| Slug collision edge cases | Low | Low | Existing slug generation handles this |
| Performance degradation | Medium | Low | Caching, database indexes, monitoring |

## Rollout Plan

### Phase 1: Development & Testing (Week 1)
- [ ] Implement TMDb ID route
- [ ] Implement IMDb ID route
- [ ] Write comprehensive tests
- [ ] Security review

### Phase 2: Staging Deployment (Week 2)
- [ ] Deploy to staging environment
- [ ] Performance testing
- [ ] Security penetration testing
- [ ] Documentation finalized

### Phase 3: Production Deployment (Week 3)
- [ ] Deploy to production (soft launch)
- [ ] Monitor metrics for 48 hours
- [ ] Notify eventasaurus team of availability
- [ ] Collect feedback

### Phase 4: Monitoring & Iteration (Ongoing)
- [ ] Monitor success rates and performance
- [ ] Tune rate limiting if needed
- [ ] Add additional sources if requested
- [ ] Optimize based on usage patterns

## Related Issues
- [Eventasaurus Issue #2414](https://github.com/razrfly/eventasaurus/issues/2414) - Original request
- Issue #192: "Many festival films missing from database" (related context)
- `.github/ISSUE_MULTI_SOURCE_MOVIE_LOOKUP.md` - Different but related (festival imports)

## References
- [TMDb API Documentation](https://developers.themoviedb.org/3)
- [TMDb External IDs Endpoint](https://developers.themoviedb.org/3/find/find-by-id)
- [Stack Overflow: TMDB to IMDB Conversion](https://stackoverflow.com/questions/59815357)
- Current implementation: `lib/cinegraph_web/live/movie_live/show.ex:40-53`
- Router: `lib/cinegraph_web/router.ex:30`

## Estimated Effort
- **Phase 1 (TMDb route)**: 2-3 hours
- **Phase 2 (IMDb route)**: 2-3 hours
- **Phase 3 (Testing & docs)**: 2-3 hours
- **Total**: **6-9 hours development time**

## Priority
**High** - Blocking external integration with eventasaurus project, enabling cross-platform movie discovery ecosystem.
