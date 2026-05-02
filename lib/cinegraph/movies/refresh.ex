defmodule Cinegraph.Movies.Refresh do
  @moduledoc """
  Shared entrypoint for enqueueing volatile external movie refresh jobs.
  """

  alias Cinegraph.Workers.{
    MovieAvailabilityRefreshWorker,
    OMDbEnrichmentWorker,
    TMDbDetailsWorker
  }

  alias Cinegraph.Movies.{Availability, Movie}
  alias Cinegraph.Repo

  require Logger

  def enqueue_movie_external_refresh(movie_id, opts \\ []) do
    case Repo.get(Movie, movie_id) do
      nil ->
        {:error, :movie_not_found}

      movie ->
        enqueue_existing_movie_refresh(movie, movie_id, opts)
    end
  end

  defp enqueue_existing_movie_refresh(movie, movie_id, opts) do
    regions = Keyword.get(opts, :regions, Availability.configured_regions())
    force? = Keyword.get(opts, :force, true)

    builders = [
      tmdb: fn ->
        if movie.tmdb_id do
          TMDbDetailsWorker.new(%{"tmdb_id" => movie.tmdb_id, "source" => "manual"})
        end
      end,
      omdb: fn -> OMDbEnrichmentWorker.new(%{"movie_id" => movie_id, "force" => force?}) end,
      availability: fn ->
        MovieAvailabilityRefreshWorker.new(%{
          "movie_id" => movie_id,
          "force" => force?,
          "source" => "manual"
        })
        |> maybe_put_regions(regions)
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

  defp maybe_put_regions(job, :all), do: job

  defp maybe_put_regions(%Ecto.Changeset{} = changeset, regions) do
    args = Ecto.Changeset.get_field(changeset, :args) || %{}
    Ecto.Changeset.put_change(changeset, :args, Map.put(args, "regions", regions))
  end
end
