defmodule Cinegraph.ApiProcessors.OMDb do
  @moduledoc """
  API processor for Open Movie Database (OMDb).

  Fetches movie data including ratings, awards, box office information,
  and additional metadata not available in TMDb.
  """

  @behaviour Cinegraph.ApiProcessors.Behaviour

  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Services.OMDb
  alias Cinegraph.Metrics
  import Ecto.Query
  require Logger

  @impl true
  def process_movie(movie_id, opts \\ []) do
    with {:ok, movie} <- get_movie(movie_id),
         {:ok, movie} <- fetch_and_update_movie(movie, opts) do
      {:ok, movie}
    end
  end

  @impl true
  def can_process?(%Movie{imdb_id: imdb_id}) when not is_nil(imdb_id), do: true
  def can_process?(_), do: false

  @impl true
  def required_identifier(), do: :imdb_id

  @impl true
  def name(), do: "OMDb"

  @impl true
  def data_field(), do: :omdb_data

  @impl true
  def has_data?(%Movie{omdb_data: data}) when not is_nil(data) and map_size(data) > 0, do: true
  def has_data?(_), do: false

  @impl true
  # Free tier: max 1000/day
  def rate_limit_ms(), do: 1000

  @impl true
  def validate_config() do
    case Application.get_env(:cinegraph, Cinegraph.Services.OMDb.Client)[:api_key] do
      nil -> {:error, "OMDB_API_KEY not configured"}
      "" -> {:error, "OMDB_API_KEY is empty"}
      _ -> :ok
    end
  end

  # Private functions

  # #923: Movie schema marks omdb_data load_in_query: false. has_data?/1 below
  # pattern-matches on %Movie{omdb_data: data} so the field MUST be selected
  # here — without the explicit opt-in, should_skip_processing? always falls
  # open and the OMDb API gets called even for already-enriched movies,
  # burning quota.
  defp get_movie(movie_id) do
    case Repo.one(
           from m in Movie,
             where: m.id == ^movie_id,
             select_merge: %{omdb_data: m.omdb_data}
         ) do
      nil -> {:error, :movie_not_found}
      movie -> {:ok, movie}
    end
  end

  defp fetch_and_update_movie(movie, opts) do
    force_refresh = Keyword.get(opts, :force_refresh, false)

    # Validate IMDb ID format
    if not valid_imdb_id?(movie.imdb_id) do
      Logger.warning("Invalid IMDb ID format for #{movie.title}: #{movie.imdb_id}")
      {:error, :invalid_imdb_id}
    else
      if should_skip_processing?(movie, force_refresh) do
        Logger.info("OMDb data already exists for #{movie.title} (ID: #{movie.id})")
        {:ok, movie}
      else
        Logger.info("Fetching OMDb data for #{movie.title} (IMDb ID: #{movie.imdb_id})")

        case fetch_and_store_omdb_data(movie) do
          {:ok, updated_movie} ->
            Logger.info("Successfully processed OMDb data for #{movie.title}")
            {:ok, updated_movie}

          {:error, reason} = error ->
            Logger.error("Failed to fetch OMDb data for #{movie.title}: #{inspect(reason)}")
            error
        end
      end
    end
  end

  defp should_skip_processing?(movie, force_refresh) do
    # #1053: the terminal test is "did we already fetch & store a response",
    # i.e. the presence of the raw blob — NOT the presence of a source='omdb'
    # external_metrics row. ExternalMetric.from_omdb/2 writes under four
    # sources (imdb/metacritic/rotten_tomatoes/omdb); a sparse OMDb response
    # (e.g. only an imdbRating) legitimately yields an `imdb` row and NO
    # `omdb` row, so gating on a source='omdb' row re-fetched those movies
    # from the API on every pass. Materialization of metrics from an existing
    # blob is handled idempotently on write (atomic store_omdb_data/2) and by
    # the JSONB backfill — not by re-hitting the API here.
    #
    # get_movie/1 opts omdb_data back in via select_merge (load_in_query:
    # false), so has_data?/1 sees the real blob. Keep that opt-in (#923).
    if force_refresh do
      false
    else
      has_data?(movie)
    end
  end

  # Indirects through Application config so tests can swap in a stub without
  # live HTTP calls. Production default: Cinegraph.Services.OMDb.Client.
  # Test override: config :cinegraph, :omdb_http_client, MyStub
  defp omdb_client, do: Application.get_env(:cinegraph, :omdb_http_client, OMDb.Client)

  defp fetch_and_store_omdb_data(movie) do
    case omdb_client().get_movie_by_imdb_id(movie.imdb_id) do
      {:ok, omdb_data} ->
        store_omdb_data(omdb_data, movie)

      {:error, "Movie not found!"} ->
        Logger.warning("Movie not found in OMDb: #{movie.title} (#{movie.imdb_id})")
        # Return an error so the worker records a fetch_attempt metric, which
        # removes this movie from the BackfillOmdb backlog and applies a 90-day
        # cooldown before the next attempt. Returning {:ok, movie} here would
        # leave no external_metrics row, causing the sweeper to re-queue forever.
        {:error, "Movie not found!"}

      # #1053: OMDb returns the literal string "Request limit reached!" when the
      # daily quota is exhausted. Map it to :rate_limited so OMDbEnrichmentWorker's
      # existing {:error, :rate_limited} -> {:snooze, 3600} branch fires. Without
      # this it falls through to {:error, reason} -> retry -> discard, which would
      # burn quota-exhausted jobs into the discarded state during an aggressive
      # backfill instead of rescheduling them.
      {:error, "Request limit reached!"} ->
        Logger.warning("OMDb daily request limit reached while processing #{movie.title}")
        {:error, :rate_limited}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp store_omdb_data(omdb_data, movie) do
    # Store the complete OMDb response in the movie record
    movie_updates = %{
      omdb_data: omdb_data
    }

    # #1053: commit the raw blob and its derived external_metrics ATOMICALLY.
    # These used to be two independent commits — `update_movie` (blob) then
    # `store_omdb_metrics` (rows). A failure/crash/deploy between them left an
    # orphaned blob (omdb_data set, no metrics), which is the root cause of the
    # ~339k materialization gap. Wrapping in a transaction makes it all-or-nothing.
    # Both calls use Cinegraph.Repo, so they enlist in the same transaction.
    txn =
      Repo.transaction(fn ->
        with {:ok, updated_movie} <- update_movie(movie, movie_updates),
             :ok <- Metrics.store_omdb_metrics(updated_movie, omdb_data) do
          updated_movie
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case txn do
      {:ok, updated_movie} -> {:ok, updated_movie}
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_movie(movie, updates) do
    movie
    |> Movie.changeset(updates)
    |> Repo.update()
  end

  # Box office parsing is now handled by Metrics.store_omdb_metrics

  # Validate IMDb ID format (tt followed by 7+ digits)
  defp valid_imdb_id?(nil), do: false

  defp valid_imdb_id?(imdb_id) do
    Regex.match?(~r/^tt\d{7,}$/, imdb_id)
  end
end
