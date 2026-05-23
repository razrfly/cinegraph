defmodule CinegraphWeb.Resolvers.MovieResolver do
  @moduledoc """
  GraphQL resolvers for movie queries.
  """

  import Ecto.Query
  import Absinthe.Resolution.Helpers, only: [on_load: 2]

  alias Cinegraph.Repo

  alias Cinegraph.Movies.{
    Availability,
    Credit,
    ExternalMetric,
    Movie,
    MovieAvailabilityRefresh,
    MovieVideo,
    MovieWatchProvider
  }

  @availability_group_order ~w(flatrate free ads rent buy)

  # ---------------------------------------------------------------------------
  # Top-level query resolvers
  # ---------------------------------------------------------------------------

  @doc false
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

  @doc false
  def movies(_, %{tmdb_ids: tmdb_ids}, _) do
    movies =
      from(m in Movie, where: m.tmdb_id in ^tmdb_ids)
      |> Repo.all()

    {:ok, movies}
  end

  @doc false
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

  @doc false
  def now_playing_movies(_, args, _) do
    limit = Map.get(args, :limit, 100)
    recency_days = Map.get(args, :recency_days)
    region = Map.get(args, :region)
    stamp_cutoff = DateTime.add(DateTime.utc_now(), -3, :day)

    movies =
      Cinegraph.Movies.Cache.now_playing_movies()
      |> then(fn list ->
        if recency_days do
          date_cutoff = Date.add(Date.utc_today(), -recency_days)

          Enum.filter(list, fn m ->
            m.release_date && Date.compare(m.release_date, date_cutoff) in [:gt, :eq]
          end)
        else
          list
        end
      end)
      |> then(fn list ->
        if region do
          Enum.filter(list, &Cinegraph.Movies.region_active?(&1, region, stamp_cutoff))
        else
          list
        end
      end)
      |> Enum.take(limit)

    {:ok, movies}
  end

  # ---------------------------------------------------------------------------
  # Child field resolvers on Movie — batched via Dataloader
  # ---------------------------------------------------------------------------

  @doc false
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

  @doc false
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

  @doc false
  def lens_scores(movie, _, %{context: %{loader: loader}}) do
    loader = Dataloader.load(loader, :db, {:score_cache, %{}}, movie)
    loader = Dataloader.load(loader, :db, {:scoreability, %{}}, movie)

    on_load(loader, fn loader ->
      cache = Dataloader.get(loader, :db, {:score_cache, %{}}, movie)
      scoreability = Dataloader.get(loader, :db, {:scoreability, %{}}, movie)

      result =
        if cache do
          %{
            mob: cache.mob_score,
            critics: cache.critics_score,
            festival_recognition: cache.festival_recognition_score,
            industry_recognition: cache.festival_recognition_score,
            time_machine: cache.time_machine_score,
            auteurs: cache.auteurs_score,
            box_office: cache.box_office_score,
            overall: cache.overall_score,
            confidence: cache.score_confidence,
            display_score: scoreability && scoreability.cinegraph_display_score,
            sort_score: scoreability && scoreability.cinegraph_sort_score,
            scoreability_state: scoreability && scoreability.scoreability_state,
            score_confidence_label: scoreability && scoreability.score_confidence_label,
            present_lens_count: scoreability && scoreability.present_lens_count,
            missing_lens_count: scoreability && scoreability.missing_lens_count,
            present_lens_labels: scoreability && scoreability.present_lens_labels,
            missing_lens_labels: scoreability && scoreability.missing_lens_labels,
            score_hidden_reason: scoreability && scoreability.score_hidden_reason,
            disparity_score: cache.disparity_score,
            disparity_category: cache.disparity_category,
            unpredictability_score: cache.unpredictability_score
          }
        else
          nil
        end

      {:ok, result}
    end)
  end

  @doc false
  def cast(movie, _, _) do
    credits =
      from(c in Credit,
        where: c.movie_id == ^movie.id and c.credit_type == "cast",
        order_by: [asc: c.cast_order]
      )
      |> Repo.all()

    {:ok, credits}
  end

  @doc false
  def crew(movie, _, _) do
    credits =
      from(c in Credit,
        where: c.movie_id == ^movie.id and c.credit_type == "crew",
        order_by: [asc: c.id]
      )
      |> Repo.all()

    {:ok, credits}
  end

  @doc false
  def videos(movie, _, _) do
    videos =
      from(v in MovieVideo, where: v.movie_id == ^movie.id, order_by: [desc: v.official])
      |> Repo.all()

    {:ok, videos}
  end

  @doc false
  def availability(movie, args, %{context: %{loader: loader}}) do
    batch_key = {:movie_availability, normalize_requested_region(Map.get(args, :region))}
    loader = Dataloader.load(loader, :availability, batch_key, movie.id)

    on_load(loader, fn loader ->
      {:ok, Dataloader.get(loader, :availability, batch_key, movie.id)}
    end)
  end

  @doc false
  def availability(movie, args, _) do
    batch_key = {:movie_availability, normalize_requested_region(Map.get(args, :region))}
    {:ok, load_availability(batch_key, [movie.id])[movie.id]}
  end

  @doc false
  def load_availability({:movie_availability, requested_region}, movie_ids) do
    movie_ids = Enum.to_list(movie_ids)
    source = "tmdb"
    regions_by_movie = available_regions_by_movie(movie_ids, source)

    selected_by_movie =
      Map.new(movie_ids, fn movie_id ->
        regions = Map.get(regions_by_movie, movie_id, [Availability.default_region()])
        {movie_id, select_availability_region(requested_region, regions)}
      end)

    selected_regions = selected_by_movie |> Map.values() |> Enum.uniq()

    option_regions =
      (selected_regions ++ Enum.flat_map(regions_by_movie, fn {_movie_id, regions} -> regions end))
      |> Enum.uniq()

    labels = option_regions |> Availability.region_options(source: source) |> Map.new()
    freshness_by_key = availability_freshness_by_key(movie_ids, selected_regions, source)
    groups_by_key = availability_groups_by_key(movie_ids, selected_regions, source)
    queued_by_key = availability_queued_by_key(movie_ids, selected_by_movie)

    Map.new(movie_ids, fn movie_id ->
      region = Map.fetch!(selected_by_movie, movie_id)
      regions = Map.get(regions_by_movie, movie_id, [Availability.default_region()])

      region_options =
        if region in regions do
          regions
        else
          [region | regions]
        end

      freshness = Map.get(freshness_by_key, {movie_id, region})

      {movie_id,
       %{
         region: region,
         region_label: Map.get(labels, region, region),
         status: availability_status(freshness),
         tmdb_link: freshness && freshness.tmdb_link,
         fetched_at: iso8601(freshness && freshness.fetched_at),
         stale_after: iso8601(freshness && freshness.stale_after),
         is_stale: stale?(freshness),
         refresh_queued: Map.get(queued_by_key, {movie_id, region}, false),
         groups: availability_groups(Map.get(groups_by_key, {movie_id, region}, %{})),
         available_regions:
           availability_region_options(Enum.map(region_options, &{&1, Map.get(labels, &1, &1)}))
       }}
    end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp available_regions_by_movie(movie_ids, source) do
    availability_regions =
      from(mwp in MovieWatchProvider,
        where: mwp.movie_id in ^movie_ids,
        where: mwp.source == ^source,
        select: {mwp.movie_id, mwp.region}
      )
      |> Repo.all()

    refresh_regions =
      from(r in MovieAvailabilityRefresh,
        where: r.movie_id in ^movie_ids,
        where: r.source == ^source,
        select: {r.movie_id, r.region}
      )
      |> Repo.all()

    (availability_regions ++ refresh_regions)
    |> Enum.group_by(fn {movie_id, _region} -> movie_id end, fn {_movie_id, region} -> region end)
    |> Map.new(fn {movie_id, regions} -> {movie_id, regions |> Enum.uniq() |> Enum.sort()} end)
  end

  defp availability_freshness_by_key(movie_ids, regions, source) do
    from(r in MovieAvailabilityRefresh,
      where: r.movie_id in ^movie_ids,
      where: r.region in ^regions,
      where: r.source == ^source
    )
    |> Repo.all()
    |> Map.new(fn row -> {{row.movie_id, row.region}, row} end)
  end

  defp availability_groups_by_key(movie_ids, regions, source) do
    rows =
      from(mwp in MovieWatchProvider,
        where: mwp.movie_id in ^movie_ids,
        where: mwp.region in ^regions,
        where: mwp.source == ^source,
        order_by: [
          asc: mwp.movie_id,
          asc: mwp.region,
          asc: mwp.monetization_type,
          asc_nulls_last: mwp.display_priority,
          asc: mwp.id
        ],
        preload: [:watch_provider]
      )
      |> Repo.all()

    rows
    |> Enum.group_by(&{&1.movie_id, &1.region})
    |> Map.new(fn {key, grouped_rows} ->
      groups =
        MovieWatchProvider.valid_monetization_types()
        |> Map.new(fn type ->
          type_rows =
            grouped_rows
            |> Enum.filter(&(&1.monetization_type == type))
            |> Enum.sort_by(&{is_nil(&1.display_priority), &1.display_priority || 999_999})

          {type, type_rows}
        end)

      {key, groups}
    end)
  end

  defp availability_queued_by_key(movie_ids, selected_by_movie) do
    movie_id_strings = Enum.map(movie_ids, &to_string/1)

    jobs =
      from(j in Oban.Job,
        where: j.worker == "Cinegraph.Workers.MovieAvailabilityRefreshWorker",
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        where: fragment("?->>'movie_id'", j.args) in ^movie_id_strings,
        select: j.args
      )
      |> Repo.all()

    Map.new(selected_by_movie, fn {movie_id, region} ->
      queued? =
        Enum.any?(jobs, fn args ->
          to_string(args["movie_id"]) == to_string(movie_id) and job_matches_region?(args, region)
        end)

      {{movie_id, region}, queued?}
    end)
  end

  defp job_matches_region?(%{"regions" => regions}, region) when is_list(regions) do
    region in Enum.map(regions, &normalize_requested_region/1)
  end

  defp job_matches_region?(_args, _region), do: true

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

  defp normalize_requested_region(region) when is_binary(region) do
    region
    |> String.trim()
    |> String.upcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_requested_region(_region), do: nil

  defp select_availability_region(region, regions) when is_binary(region) do
    normalized = normalize_requested_region(region)

    cond do
      is_nil(normalized) -> select_availability_region(nil, regions)
      normalized in regions -> normalized
      Availability.supported_region?(normalized) -> normalized
      true -> select_availability_region(nil, regions)
    end
  end

  defp select_availability_region(_region, regions) do
    cond do
      Availability.default_region() in regions -> Availability.default_region()
      regions != [] -> List.first(regions)
      true -> Availability.default_region()
    end
  end

  defp availability_status(nil), do: "never_fetched"
  defp availability_status(%{status: status}), do: status

  defp stale?(%{stale_after: %DateTime{} = stale_after}) do
    DateTime.compare(stale_after, DateTime.utc_now()) == :lt
  end

  defp stale?(_), do: false

  defp availability_groups(groups) do
    Enum.map(@availability_group_order, fn type ->
      rows = Map.get(groups, type, [])

      %{
        monetization_type: type,
        label: availability_group_label(type),
        providers: Enum.map(rows, &availability_row/1)
      }
    end)
  end

  defp availability_row(row) do
    %{
      monetization_type: row.monetization_type,
      display_priority: row.display_priority,
      tmdb_link: row.tmdb_link,
      fetched_at: iso8601(row.fetched_at),
      stale_after: iso8601(row.stale_after),
      provider: watch_provider(row.watch_provider)
    }
  end

  defp watch_provider(nil), do: nil

  defp watch_provider(provider) do
    %{
      source: provider.source,
      source_provider_id: provider.source_provider_id,
      tmdb_provider_id: provider.tmdb_provider_id,
      name: provider.name,
      logo_path: provider.logo_path,
      logo_url: tmdb_logo_url(provider.logo_path),
      display_priorities: provider.display_priorities
    }
  end

  defp availability_region_options(region_options) do
    Enum.map(region_options, fn {region, label} ->
      %{region: region, label: label}
    end)
  end

  defp availability_group_label("flatrate"), do: "Streaming"
  defp availability_group_label("free"), do: "Free"
  defp availability_group_label("ads"), do: "Free with ads"
  defp availability_group_label("rent"), do: "Rent"
  defp availability_group_label("buy"), do: "Buy"
  defp availability_group_label(type), do: type

  defp tmdb_logo_url(nil), do: nil
  defp tmdb_logo_url(""), do: nil
  defp tmdb_logo_url(path), do: "https://image.tmdb.org/t/p/w92#{path}"

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
end
