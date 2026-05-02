defmodule Cinegraph.Movies.Refresh do
  @moduledoc """
  Shared entrypoint for enqueueing volatile external movie refresh jobs.
  """

  alias Cinegraph.Workers.{
    MovieAvailabilityRefreshWorker,
    OMDbEnrichmentWorker,
    TMDbDetailsWorker
  }

  alias Cinegraph.Movies.Movie
  alias Cinegraph.Repo

  require Logger

  def enqueue_movie_external_refresh(movie_id, opts \\ []) do
    movie = Repo.get(Movie, movie_id)
    regions = Keyword.get(opts, :regions, ["US"])
    force? = Keyword.get(opts, :force, true)

    builders = [
      tmdb: fn ->
        if movie && movie.tmdb_id do
          TMDbDetailsWorker.new(%{"tmdb_id" => movie.tmdb_id, "source" => "manual"})
        end
      end,
      omdb: fn -> OMDbEnrichmentWorker.new(%{"movie_id" => movie_id, "force" => force?}) end,
      availability: fn ->
        MovieAvailabilityRefreshWorker.new(%{
          "movie_id" => movie_id,
          "regions" => regions,
          "force" => force?,
          "source" => "manual"
        })
      end
    ]

    {queued, errors} =
      Enum.reduce(builders, {[], []}, fn {key, builder}, {ok, errs} ->
        if Keyword.get(opts, key, false) do
          case builder.() do
            nil ->
              {ok, [{key, :missing_movie_or_tmdb_id} | errs]}

            job ->
              case Oban.insert(job) do
                {:ok, _job} ->
                  {[key | ok], errs}

                {:error, %Ecto.Changeset{errors: [args: {"has already been taken", _}]}} ->
                  {[key | ok], errs}

                {:error, reason} ->
                  {ok, [{key, reason} | errs]}
              end
          end
        else
          {ok, errs}
        end
      end)

    if errors == [] do
      {:ok, Enum.reverse(queued)}
    else
      Logger.warning("Movies.Refresh enqueue failed partially: #{inspect(errors)}")
      {:error, %{queued: Enum.reverse(queued), errors: errors}}
    end
  end
end
