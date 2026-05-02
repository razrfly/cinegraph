defmodule Cinegraph.Movies.Search do
  @moduledoc """
  Clean search interface that combines Flop with custom filters.
  This is the new unified interface for movie searching.

  All read operations use `Repo.replica()` to offload queries to
  PlanetScale read replicas, reducing load on the primary database.
  """

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Movies.{DiscoveryRankings, Movie, MovieScoreCache}
  alias Cinegraph.Movies.Query.{Params, CustomFilters, CustomSorting}
  alias Cinegraph.Metrics.ScoringService
  alias Cinegraph.Workers.MovieScoreCacheWorker

  defmacrop score_cache_present_lens_count_fragment(sc) do
    quote do
      fragment(
        """
        (
          (COALESCE(?, 0) > 0)::int +
          (COALESCE(?, 0) > 0)::int +
          (COALESCE(?, 0) > 0)::int +
          (COALESCE(?, 0) > 0)::int +
          (COALESCE(?, 0) > 0)::int +
          (COALESCE(?, 0) > 0)::int
        )
        """,
        unquote(sc).mob_score,
        unquote(sc).critics_score,
        unquote(sc).festival_recognition_score,
        unquote(sc).time_machine_score,
        unquote(sc).auteurs_score,
        unquote(sc).box_office_score
      )
    end
  end

  defmacrop score_cache_present_lens_labels_fragment(sc) do
    quote do
      fragment(
        """
        ARRAY_REMOVE(ARRAY[
          CASE WHEN COALESCE(?, 0) > 0 THEN 'mob' END,
          CASE WHEN COALESCE(?, 0) > 0 THEN 'critics' END,
          CASE WHEN COALESCE(?, 0) > 0 THEN 'festival_recognition' END,
          CASE WHEN COALESCE(?, 0) > 0 THEN 'time_machine' END,
          CASE WHEN COALESCE(?, 0) > 0 THEN 'auteurs' END,
          CASE WHEN COALESCE(?, 0) > 0 THEN 'box_office' END
        ], NULL)
        """,
        unquote(sc).mob_score,
        unquote(sc).critics_score,
        unquote(sc).festival_recognition_score,
        unquote(sc).time_machine_score,
        unquote(sc).auteurs_score,
        unquote(sc).box_office_score
      )
    end
  end

  defmacrop score_cache_missing_lens_labels_fragment(sc) do
    quote do
      fragment(
        """
        ARRAY_REMOVE(ARRAY[
          CASE WHEN COALESCE(?, 0) <= 0 THEN 'mob' END,
          CASE WHEN COALESCE(?, 0) <= 0 THEN 'critics' END,
          CASE WHEN COALESCE(?, 0) <= 0 THEN 'festival_recognition' END,
          CASE WHEN COALESCE(?, 0) <= 0 THEN 'time_machine' END,
          CASE WHEN COALESCE(?, 0) <= 0 THEN 'auteurs' END,
          CASE WHEN COALESCE(?, 0) <= 0 THEN 'box_office' END
        ], NULL)
        """,
        unquote(sc).mob_score,
        unquote(sc).critics_score,
        unquote(sc).festival_recognition_score,
        unquote(sc).time_machine_score,
        unquote(sc).auteurs_score,
        unquote(sc).box_office_score
      )
    end
  end

  @preset_sort_variants ~w(
    cinegraph_editorial cinegraph_editorial_asc cinegraph_editorial_desc
    critics_choice critics_choice_asc critics_choice_desc
    crowd_pleaser crowd_pleaser_asc crowd_pleaser_desc
    award_season award_season_asc award_season_desc
    hidden_gems hidden_gems_asc hidden_gems_desc
  )

  @doc """
  Search movies with validated parameters.
  Returns {movies, meta} tuple where meta contains pagination info.
  Phase 2: Uses cache to avoid repeated database queries.
  """
  def search_movies(params \\ %{}) do
    # Use cache wrapper for search results (Phase 2 optimization)
    Cinegraph.Movies.Cache.get_search_results(params, fn ->
      search_movies_uncached(params)
    end)
  end

  @doc """
  Search movies without caching (internal use).
  This is the actual search implementation that gets cached.
  """
  def search_movies_uncached(params) do
    with {:ok, validated_params} <- Params.validate(params) do
      if DiscoveryRankings.default_browse?(validated_params) do
        DiscoveryRankings.list_default(validated_params)
      else
        search_movies_generic(validated_params)
      end
    end
  end

  defp search_movies_generic(validated_params) do
    if plain_score_sort?(validated_params) do
      search_movies_plain_score_sort(validated_params)
    else
      search_movies_generic_query(validated_params)
    end
  end

  defp search_movies_generic_query(validated_params) do
    # Start with base query for fully imported movies
    base_query = from(m in Movie, where: m.import_status == "full")

    # Apply custom filters first (genres, awards, people, etc.)
    filtered_query = CustomFilters.apply_all(base_query, validated_params)

    # Check if we need custom sorting
    needs_custom_sort =
      validated_params.sort in ~w(
          rating rating_asc rating_desc
          popularity popularity_asc popularity_desc
          discovery_score discovery_score_asc discovery_score_desc
          score score_asc score_desc
          mob mob_asc mob_desc
          critics critics_asc critics_desc
          festival_recognition festival_recognition_asc festival_recognition_desc
          time_machine time_machine_asc time_machine_desc
          auteurs auteurs_asc auteurs_desc
          box_office box_office_asc box_office_desc
        ) or validated_params.sort in @preset_sort_variants

    # Resolve preset weights for score-cache sorts
    preset_slug =
      cond do
        validated_params.sort in @preset_sort_variants ->
          String.replace(validated_params.sort, ~r/_(asc|desc)$/, "")

        validated_params.sort in ~w(score score_asc score_desc) and
            not is_nil(validated_params.preset) ->
          validated_params.preset

        true ->
          nil
      end

    preset_weights =
      if preset_slug do
        case ScoringService.get_profile_by_slug(preset_slug) do
          nil -> nil
          profile -> profile.category_weights
        end
      else
        nil
      end

    # Apply custom sorting if needed
    sorted_query =
      if needs_custom_sort do
        CustomSorting.apply(filtered_query, validated_params.sort, preset_weights)
      else
        filtered_query
      end

    # Convert params to Flop format
    flop_params = Params.to_flop_params(validated_params)

    # If we applied custom sorting, remove order from Flop params
    flop_params =
      if needs_custom_sort do
        Map.delete(flop_params, :order_by)
      else
        flop_params
      end

    # Use Flop for remaining filters, sorting (if not custom), and pagination
    # Route to read replica for better load distribution
    case Flop.validate_and_run(sorted_query, flop_params, for: Movie, repo: Repo.replica()) do
      {:ok, {movies, meta}} ->
        # Add discovery scores for display if not using discovery sorting
        movies = maybe_add_discovery_scores(movies, validated_params.sort)
        {:ok, {movies, meta}}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp search_movies_plain_score_sort(validated_params) do
    page = validated_params.page || 1
    per_page = validated_params.per_page || 50
    offset = (page - 1) * per_page
    direction = score_sort_direction(validated_params.sort)

    total_count = count_plain_score_sort_movies(validated_params)
    scoreable_count = count_plain_score_sort_scoreable_movies(validated_params)

    movies =
      cond do
        offset >= scoreable_count ->
          fetch_plain_score_sort_insufficient(
            validated_params,
            offset - scoreable_count,
            per_page
          )

        offset + per_page <= scoreable_count ->
          fetch_plain_score_sort_scoreable(validated_params, direction, offset, per_page)

        true ->
          scoreable_limit = max(scoreable_count - offset, 0)
          insufficient_limit = per_page - scoreable_limit

          fetch_plain_score_sort_scoreable(validated_params, direction, offset, scoreable_limit) ++
            fetch_plain_score_sort_insufficient(validated_params, 0, insufficient_limit)
      end

    {:ok, {movies, search_meta(page, per_page, total_count)}}
  end

  @doc """
  Count total movies matching the filters.
  This is useful for showing total results without loading all data.
  """
  def count_movies(params \\ %{}) do
    with {:ok, validated_params} <- Params.validate(params) do
      if DiscoveryRankings.default_browse?(validated_params) do
        {:ok, DiscoveryRankings.count_default()}
      else
        base_query = from(m in Movie, where: m.import_status == "full")
        filtered_query = CustomFilters.apply_all(base_query, validated_params)

        # Handle special case for genre filtering with GROUP BY
        # Route to read replica for better load distribution
        count =
          if validated_params.genres && validated_params.genres != [] do
            # Wrap the grouped query in a subquery and count the results
            from(m in subquery(filtered_query), select: count())
            |> Repo.replica().one()
          else
            Repo.replica().aggregate(filtered_query, :count, :id)
          end

        {:ok, count}
      end
    end
  end

  @doc """
  Get filter options for the UI.
  Returns all available values for dropdowns and multiselects.
  Uses cache to avoid repeated database queries (Phase 1 optimization).
  """
  def get_filter_options do
    Cinegraph.Movies.Cache.get_filter_options(fn ->
      %{
        genres: list_genres(),
        countries: list_production_countries(),
        languages: list_spoken_languages(),
        lists: list_canonical_lists(),
        decades: generate_decades(),
        festivals: list_festival_organizations(),
        sort_options: get_sort_options(),
        rating_presets: get_rating_presets(),
        discovery_presets: get_discovery_presets(),
        award_presets: get_award_presets(),
        people_roles: get_people_roles()
      }
    end)
  end

  @doc """
  Search for people to use in filters.
  """
  def search_people(query_string, limit \\ 10) do
    Cinegraph.People.search_people(query_string, limit: limit)
  end

  @doc """
  Get people by IDs for displaying selected filters.
  """
  def get_people_by_ids(ids) when is_list(ids) do
    Cinegraph.People.get_people_by_ids(ids)
  end

  # Private functions

  defp maybe_add_discovery_scores(movies, sort) do
    if uses_discovery_sorting?(sort) do
      # Discovery scores are already being used for sorting
      movies
    else
      # For now, skip adding scores when using Flop for basic sorting
      # TODO: Implement ScoringService.add_scores_to_loaded_movies/2 for this case
      movies
    end
  end

  defp plain_score_sort?(%Params{} = params) do
    params.sort in ~w(score score_asc score_desc) and
      is_nil(params.preset) and
      is_nil(params.search) and
      params.genres == [] and
      params.countries == [] and
      params.languages == [] and
      params.lists == [] and
      is_nil(params.year) and
      is_nil(params.year_from) and
      is_nil(params.year_to) and
      is_nil(params.decade) and
      is_nil(params.runtime_min) and
      is_nil(params.runtime_max) and
      is_nil(params.rating_min) and
      is_nil(params.award_status) and
      is_nil(params.festival_id) and
      params.festivals == [] and
      is_nil(params.award_category_id) and
      is_nil(params.award_year_from) and
      is_nil(params.award_year_to) and
      is_nil(params.rating_preset) and
      is_nil(params.discovery_preset) and
      is_nil(params.award_preset) and
      params.people_ids == [] and
      is_nil(params.people_role) and
      params.people_match == "any" and
      params.production_company_ids == [] and
      is_nil(params.festival_recognition_min) and
      is_nil(params.time_machine_min) and
      is_nil(params.auteurs_min) and
      is_nil(params.disparity)
  end

  defp score_sort_direction("score_asc"), do: :asc_nulls_last
  defp score_sort_direction(_), do: :desc_nulls_last

  defp count_plain_score_sort_movies(params) do
    Movie
    |> where([m], m.import_status == "full")
    |> maybe_released_only_movie(params)
    |> Repo.replica().aggregate(:count, :id)
  end

  defp count_plain_score_sort_scoreable_movies(params) do
    current_version = MovieScoreCacheWorker.current_version()

    MovieScoreCache
    |> join(:inner, [sc], m in Movie, on: m.id == sc.movie_id)
    |> where([sc, m], m.import_status == "full")
    |> maybe_released_only_score_cache_movie(params)
    |> where([sc], sc.calculation_version == ^current_version)
    |> where([sc], not is_nil(sc.overall_score))
    |> where([sc], score_cache_present_lens_count_fragment(sc) >= 2)
    |> Repo.replica().aggregate(:count, :id)
  end

  defp fetch_plain_score_sort_scoreable(_params, _direction, _offset, limit) when limit <= 0,
    do: []

  defp fetch_plain_score_sort_scoreable(params, direction, offset, limit) do
    current_version = MovieScoreCacheWorker.current_version()

    MovieScoreCache
    |> join(:inner, [sc], m in Movie, on: m.id == sc.movie_id)
    |> where([sc, m], m.import_status == "full")
    |> maybe_released_only_score_cache_movie(params)
    |> where([sc], sc.calculation_version == ^current_version)
    |> where([sc], not is_nil(sc.overall_score))
    |> where([sc], score_cache_present_lens_count_fragment(sc) >= 2)
    |> order_by([sc, m], [
      {^direction,
       fragment(
         "? * (?::float / 6.0)",
         sc.overall_score,
         score_cache_present_lens_count_fragment(sc)
       )},
      desc_nulls_last: m.release_date,
      asc: m.id
    ])
    |> limit(^limit)
    |> offset(^offset)
    |> select([sc, m], m)
    |> select_merge([sc, _m], %{
      overall_score: sc.overall_score,
      raw_cinegraph_score: sc.overall_score,
      score_confidence: sc.score_confidence,
      mob_score: sc.mob_score,
      critics_score: sc.critics_score,
      cinegraph_display_score: sc.overall_score,
      cinegraph_sort_score:
        fragment(
          "? * (?::float / 6.0)",
          sc.overall_score,
          score_cache_present_lens_count_fragment(sc)
        ),
      scoreability_state:
        fragment(
          "CASE WHEN ? >= 4 THEN 'scoreable' ELSE 'limited' END",
          score_cache_present_lens_count_fragment(sc)
        ),
      score_confidence_label:
        fragment(
          "CASE WHEN ? >= 5 THEN 'high' WHEN ? >= 3 THEN 'medium' ELSE 'low' END",
          score_cache_present_lens_count_fragment(sc),
          score_cache_present_lens_count_fragment(sc)
        ),
      present_lens_count: score_cache_present_lens_count_fragment(sc),
      missing_lens_count: fragment("6 - ?", score_cache_present_lens_count_fragment(sc)),
      present_lens_labels: score_cache_present_lens_labels_fragment(sc),
      missing_lens_labels: score_cache_missing_lens_labels_fragment(sc),
      evidence_confidence:
        fragment(
          "ROUND((?::numeric / 6.0), 3)::double precision",
          score_cache_present_lens_count_fragment(sc)
        ),
      cohort_percentile: fragment("NULL::double precision"),
      score_hidden_reason: fragment("'none'"),
      score_explanation_short:
        fragment(
          "CASE WHEN ? BETWEEN 2 AND 3 THEN 'Limited confidence' WHEN ? >= 5 THEN 'High confidence' ELSE 'Medium confidence' END",
          score_cache_present_lens_count_fragment(sc),
          score_cache_present_lens_count_fragment(sc)
        ),
      score_explanation_detail:
        fragment(
          "CASE WHEN ? BETWEEN 2 AND 3 THEN 'This score is based on limited evidence and may move as more lenses become available.' ELSE 'This movie has enough independent evidence for a CineGraph score.' END",
          score_cache_present_lens_count_fragment(sc)
        )
    })
    |> Repo.replica().all()
  end

  defp fetch_plain_score_sort_insufficient(_params, _offset, limit) when limit <= 0, do: []

  defp fetch_plain_score_sort_insufficient(params, offset, limit) do
    current_version = MovieScoreCacheWorker.current_version()

    Movie
    |> join(:left, [m], sc in MovieScoreCache,
      on: sc.movie_id == m.id and sc.calculation_version == ^current_version
    )
    |> where([m, sc], m.import_status == "full")
    |> maybe_released_only_movie_score_cache(params)
    |> where(
      [m, sc],
      is_nil(sc.id) or is_nil(sc.overall_score) or
        score_cache_present_lens_count_fragment(sc) < 2
    )
    |> order_by([m, _sc], desc_nulls_last: m.release_date, asc: m.id)
    |> limit(^limit)
    |> offset(^offset)
    |> select([m, sc], m)
    |> select_merge([_m, sc], %{
      overall_score: nil,
      raw_cinegraph_score: sc.overall_score,
      cinegraph_display_score: nil,
      cinegraph_sort_score: nil,
      scoreability_state: fragment("'insufficient_evidence'"),
      score_confidence_label: fragment("'insufficient'"),
      present_lens_count:
        fragment(
          "CASE WHEN ?.id IS NULL THEN 0 ELSE ? END",
          sc,
          score_cache_present_lens_count_fragment(sc)
        ),
      missing_lens_count:
        fragment(
          "CASE WHEN ?.id IS NULL THEN 6 ELSE 6 - ? END",
          sc,
          score_cache_present_lens_count_fragment(sc)
        ),
      present_lens_labels:
        fragment(
          "CASE WHEN ?.id IS NULL THEN ARRAY[]::text[] ELSE ? END",
          sc,
          score_cache_present_lens_labels_fragment(sc)
        ),
      missing_lens_labels:
        fragment(
          "CASE WHEN ?.id IS NULL THEN ARRAY['mob', 'critics', 'festival_recognition', 'time_machine', 'auteurs', 'box_office'] ELSE ? END",
          sc,
          score_cache_missing_lens_labels_fragment(sc)
        ),
      evidence_confidence:
        fragment(
          "CASE WHEN ?.id IS NULL THEN 0.0 ELSE ROUND((?::numeric / 6.0), 3)::double precision END",
          sc,
          score_cache_present_lens_count_fragment(sc)
        ),
      cohort_percentile: fragment("NULL::double precision"),
      score_hidden_reason:
        fragment(
          "CASE WHEN ?.id IS NULL OR ? IS NULL THEN 'no_score_cache' ELSE 'not_enough_evidence' END",
          sc,
          sc.overall_score
        ),
      score_explanation_short: fragment("'Not enough evidence yet'"),
      score_explanation_detail:
        fragment(
          "CASE WHEN ?.id IS NULL THEN 'No CineGraph score cache is available for this movie yet.' ELSE 'CineGraph needs at least 2 independent evidence lenses before showing a fair numeric score.' END",
          sc
        )
    })
    |> Repo.replica().all()
  end

  defp maybe_released_only_movie(query, %{show_unreleased: true}), do: query

  defp maybe_released_only_movie(query, _params) do
    where(query, [m], is_nil(m.release_date) or m.release_date <= ^Date.utc_today())
  end

  defp maybe_released_only_score_cache_movie(query, %{show_unreleased: true}), do: query

  defp maybe_released_only_score_cache_movie(query, _params) do
    where(query, [_sc, m], is_nil(m.release_date) or m.release_date <= ^Date.utc_today())
  end

  defp maybe_released_only_movie_score_cache(query, %{show_unreleased: true}), do: query

  defp maybe_released_only_movie_score_cache(query, _params) do
    where(query, [m, _sc], is_nil(m.release_date) or m.release_date <= ^Date.utc_today())
  end

  defp search_meta(page, per_page, total_count) do
    total_pages =
      case total_count do
        0 -> 0
        count -> ceil(count / per_page)
      end

    %Flop.Meta{
      current_offset: (page - 1) * per_page,
      current_page: page,
      page_size: per_page,
      next_offset: next_offset(page, per_page, total_pages),
      next_page: next_page(page, total_pages),
      previous_offset: previous_offset(page, per_page),
      previous_page: previous_page(page),
      total_count: total_count,
      total_pages: total_pages,
      has_next_page?: page < total_pages,
      has_previous_page?: page > 1,
      schema: Movie,
      flop: %Flop{page: page, page_size: per_page}
    }
  end

  defp next_offset(page, per_page, total_pages) when page < total_pages, do: page * per_page
  defp next_offset(_page, _per_page, _total_pages), do: nil

  defp next_page(page, total_pages) when page < total_pages, do: page + 1
  defp next_page(_page, _total_pages), do: nil

  defp previous_offset(page, per_page) when page > 1, do: max((page - 2) * per_page, 0)
  defp previous_offset(_page, _per_page), do: nil

  defp previous_page(page) when page > 1, do: page - 1
  defp previous_page(_page), do: nil

  defp uses_discovery_sorting?(sort) do
    base =
      cond do
        is_binary(sort) and String.ends_with?(sort, "_desc") ->
          String.replace_suffix(sort, "_desc", "")

        is_binary(sort) and String.ends_with?(sort, "_asc") ->
          String.replace_suffix(sort, "_asc", "")

        true ->
          sort
      end

    base in ~w(discovery_score mob critics festival_recognition time_machine auteurs box_office)
  end

  defp list_genres do
    from(g in Cinegraph.Movies.Genre, order_by: g.name)
    |> Repo.replica().all()
  end

  defp list_production_countries do
    from(c in Cinegraph.Movies.ProductionCountry, order_by: c.name)
    |> Repo.replica().all()
  end

  defp list_spoken_languages do
    from(l in Cinegraph.Movies.SpokenLanguage, order_by: l.english_name)
    |> Repo.replica().all()
  end

  defp list_canonical_lists do
    from(ml in Cinegraph.Movies.MovieList,
      where: ml.active == true,
      select: %{id: ml.source_key, key: ml.source_key, slug: ml.slug, name: ml.name},
      order_by: ml.name
    )
    |> Repo.replica().all()
  end

  defp generate_decades do
    current_year = Date.utc_today().year
    start_decade = 1900

    for decade <- start_decade..current_year//10 do
      %{id: decade, value: decade, label: "#{decade}s"}
    end
    |> Enum.reverse()
  end

  defp list_festival_organizations do
    from(fo in "festival_organizations",
      select: %{id: fo.id, name: fo.name, slug: fo.slug, abbreviation: fo.abbreviation},
      order_by: fo.name
    )
    |> Repo.replica().all()
  end

  defp get_sort_options do
    [
      %{
        id: "discovery_score_desc",
        value: "discovery_score_desc",
        label: "Discovery (Recent + Relevant)"
      },
      %{id: "release_date_desc", value: "release_date_desc", label: "Release Date (Newest)"},
      %{id: "release_date", value: "release_date", label: "Release Date (Oldest)"},
      %{id: "title", value: "title", label: "Title (A-Z)"},
      %{id: "title_desc", value: "title_desc", label: "Title (Z-A)"},
      %{id: "runtime", value: "runtime", label: "Runtime (Shortest)"},
      %{id: "runtime_desc", value: "runtime_desc", label: "Runtime (Longest)"},
      %{id: "rating", value: "rating", label: "Rating (Highest)"},
      %{id: "popularity", value: "popularity", label: "Popularity"},
      %{id: "mob", value: "mob", label: "The Mob (Audience)"},
      %{id: "critics", value: "critics", label: "The Critics"},
      %{id: "festival_recognition", value: "festival_recognition", label: "Industry Recognition"},
      %{id: "time_machine", value: "time_machine", label: "The Time Machine"},
      %{id: "auteurs", value: "auteurs", label: "The Auteurs"},
      %{id: "box_office", value: "box_office", label: "The Box Office"}
    ]
  end

  defp get_rating_presets do
    [
      %{id: "highly_rated", value: "highly_rated", label: "Highly Rated (7.5+)"},
      %{id: "well_reviewed", value: "well_reviewed", label: "Well Reviewed (6.0+)"},
      %{id: "critically_acclaimed", value: "critically_acclaimed", label: "Critically Acclaimed"}
    ]
  end

  defp get_discovery_presets do
    [
      %{id: "award_winners", value: "award_winners", label: "Award Winners"},
      %{id: "popular_favorites", value: "popular_favorites", label: "Popular Favorites"},
      %{id: "hidden_gems", value: "hidden_gems", label: "Hidden Gems"},
      %{id: "critically_acclaimed", value: "critically_acclaimed", label: "Critically Acclaimed"}
    ]
  end

  defp get_award_presets do
    [
      %{id: "recent_awards", value: "recent_awards", label: "Recent Awards (2020+)"},
      %{id: "2010s", value: "2010s", label: "2010s Awards"},
      %{id: "2000s", value: "2000s", label: "2000s Awards"},
      %{id: "classic", value: "classic", label: "Classic Awards (Pre-2000)"}
    ]
  end

  defp get_people_roles do
    [
      %{id: "any", value: "any", label: "Any Role"},
      %{id: "director", value: "director", label: "Director"},
      %{id: "cast", value: "cast", label: "Cast"},
      %{id: "writer", value: "writer", label: "Writer"},
      %{id: "producer", value: "producer", label: "Producer"},
      %{id: "cinematographer", value: "cinematographer", label: "Cinematographer"},
      %{id: "composer", value: "composer", label: "Composer"},
      %{id: "editor", value: "editor", label: "Editor"}
    ]
  end
end
