defmodule CinegraphWeb.Resolvers.MovieResolver do
  @moduledoc """
  GraphQL resolvers for movie queries.
  """

  import Ecto.Query
  import Absinthe.Resolution.Helpers, only: [on_load: 2]

  alias Cinegraph.Repo
  alias Cinegraph.Movies.{Movie, Credit, ExternalMetric, MovieVideo}

  # ---------------------------------------------------------------------------
  # Top-level query resolvers
  # ---------------------------------------------------------------------------

  def movie(_, args, _) do
    cond do
      tmdb_id = args[:tmdb_id] ->
        fetch_movie(:tmdb_id, tmdb_id)

      imdb_id = args[:imdb_id] ->
        fetch_movie(:imdb_id, imdb_id)

      slug = args[:slug] ->
        fetch_movie(:slug, slug)

      true ->
        {:error, "Must provide tmdb_id, imdb_id, or slug"}
    end
  end

  def movies(_, %{tmdb_ids: tmdb_ids}, _) do
    movies =
      from(m in Movie, where: m.tmdb_id in ^tmdb_ids)
      |> Repo.all()

    {:ok, movies}
  end

  def search_movies(_, %{query: query} = args, _) do
    limit = Map.get(args, :limit, 10)
    year = Map.get(args, :year)

    search_term = "%#{query}%"

    base_query =
      from(m in Movie,
        where: m.import_status == "full",
        where: ilike(m.title, ^search_term),
        order_by: [desc: m.release_date],
        limit: ^limit
      )

    results =
      base_query
      |> maybe_filter_year(year)
      |> Repo.all()

    {:ok, results}
  end

  # ---------------------------------------------------------------------------
  # Child field resolvers on Movie — batched via Dataloader
  # ---------------------------------------------------------------------------

  def ratings(movie, _, %{context: %{loader: loader}}) do
    loader = Dataloader.load(loader, :db, {:external_metrics, %{}}, movie)

    on_load(loader, fn loader ->
      metrics = Dataloader.get(loader, :db, {:external_metrics, %{}}, movie)

      result = %{
        tmdb: find_value(metrics, "tmdb", "rating_average"),
        tmdb_votes: float_to_int(find_value(metrics, "tmdb", "rating_votes")),
        imdb: find_value(metrics, "imdb", "rating_average"),
        imdb_votes: float_to_int(find_value(metrics, "imdb", "rating_votes")),
        rotten_tomatoes: float_to_int(find_value(metrics, "rotten_tomatoes", "tomatometer")),
        metacritic: float_to_int(find_value(metrics, "metacritic", "metascore"))
      }

      {:ok, result}
    end)
  end

  def awards(movie, _, _) do
    metric =
      Repo.one(
        from em in ExternalMetric,
          where:
            em.movie_id == ^movie.id and em.source == "omdb" and
              em.metric_type == "awards_summary",
          order_by: [desc: em.fetched_at],
          limit: 1
      )

    case metric do
      nil ->
        {:ok, nil}

      m ->
        result = %{
          summary: m.text_value,
          oscar_wins: get_in(m.metadata, ["oscar_wins"]),
          total_wins: get_in(m.metadata, ["total_wins"]),
          total_nominations: get_in(m.metadata, ["total_nominations"])
        }

        {:ok, result}
    end
  end

  # Both cri_score and cri_breakdown use the same Dataloader key so
  # Dataloader deduplicates the DB query when both fields are requested.
  def cri_score(movie, _, %{context: %{loader: loader}}) do
    loader = Dataloader.load(loader, :db, {:cri_score, %{}}, movie)

    on_load(loader, fn loader ->
      score = Dataloader.get(loader, :db, {:cri_score, %{}}, movie)
      {:ok, score && score.overall_score}
    end)
  end

  def cri_breakdown(movie, _, %{context: %{loader: loader}}) do
    loader = Dataloader.load(loader, :db, {:cri_score, %{}}, movie)

    on_load(loader, fn loader ->
      score = Dataloader.get(loader, :db, {:cri_score, %{}}, movie)
      {:ok, score}
    end)
  end

  def cast(movie, _, _) do
    credits =
      from(c in Credit,
        where: c.movie_id == ^movie.id and c.credit_type == "cast",
        order_by: [asc: c.cast_order]
      )
      |> Repo.all()

    {:ok, credits}
  end

  def crew(movie, _, _) do
    credits =
      from(c in Credit,
        where: c.movie_id == ^movie.id and c.credit_type == "crew",
        order_by: [asc: c.id]
      )
      |> Repo.all()

    {:ok, credits}
  end

  def videos(movie, _, _) do
    videos =
      from(v in MovieVideo, where: v.movie_id == ^movie.id, order_by: [desc: v.official])
      |> Repo.all()

    {:ok, videos}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_movie(field, value) do
    case Repo.get_by(Movie, [{field, value}]) do
      nil -> {:error, "Movie not found"}
      movie -> {:ok, movie}
    end
  end

  defp maybe_filter_year(query, nil), do: query

  defp maybe_filter_year(query, year) do
    from(m in query,
      where: fragment("EXTRACT(YEAR FROM ?)::int = ?", m.release_date, ^year)
    )
  end

  defp find_value(metrics, source, type) when is_list(metrics) do
    case Enum.find(metrics, fn m -> m.source == source and m.metric_type == type end) do
      nil -> nil
      metric -> metric.value
    end
  end

  defp find_value(_, _, _), do: nil

  defp float_to_int(nil), do: nil
  defp float_to_int(v), do: round(v)
end
