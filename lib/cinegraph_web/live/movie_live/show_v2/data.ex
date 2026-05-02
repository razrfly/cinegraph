defmodule CinegraphWeb.MovieLive.ShowV2.Data do
  @moduledoc """
  Data-loading helpers for the V2 movie show page.
  """

  import Ecto.Query

  alias Cinegraph.Cultural
  alias Cinegraph.ExternalSources
  alias Cinegraph.Metrics
  alias Cinegraph.Metrics.DisparityCalculator
  alias Cinegraph.Movies
  alias Cinegraph.Movies.Availability
  alias Cinegraph.Movies.MovieCollaborations
  alias Cinegraph.Movies.MovieScoring
  alias Cinegraph.Repo
  alias CinegraphWeb.MovieLive.ShowV2Availability
  alias Cinegraph.Workers.MovieScoreCacheWorker

  @language_region_fallbacks %{
    "pl" => "PL",
    "en" => "US",
    "fr" => "FR",
    "de" => "DE",
    "it" => "IT",
    "pt" => "PT",
    "ja" => "JP",
    "ko" => "KR",
    "hi" => "IN",
    "ar" => "EG",
    "nl" => "NL",
    "sv" => "SE",
    "no" => "NO",
    "da" => "DK",
    "fi" => "FI",
    "tr" => "TR",
    "uk" => "UA"
  }

  @timezone_region_prefixes [
    {"Europe/Warsaw", "PL"},
    {"Europe/London", "GB"},
    {"Europe/Dublin", "IE"},
    {"Europe/Paris", "FR"},
    {"Europe/Berlin", "DE"},
    {"Europe/Rome", "IT"},
    {"Europe/Madrid", "ES"},
    {"Europe/Lisbon", "PT"},
    {"Europe/Amsterdam", "NL"},
    {"Europe/Brussels", "BE"},
    {"Europe/Vienna", "AT"},
    {"Europe/Zurich", "CH"},
    {"Europe/Stockholm", "SE"},
    {"Europe/Oslo", "NO"},
    {"Europe/Copenhagen", "DK"},
    {"Europe/Helsinki", "FI"},
    {"Europe/Athens", "GR"},
    {"Europe/Istanbul", "TR"},
    {"Europe/Kyiv", "UA"},
    {"America/New_York", "US"},
    {"America/Chicago", "US"},
    {"America/Denver", "US"},
    {"America/Los_Angeles", "US"},
    {"America/Phoenix", "US"},
    {"America/Anchorage", "US"},
    {"Pacific/Honolulu", "US"},
    {"America/Toronto", "CA"},
    {"America/Vancouver", "CA"},
    {"America/Mexico_City", "MX"},
    {"America/Sao_Paulo", "BR"},
    {"America/Argentina", "AR"},
    {"Asia/Tokyo", "JP"},
    {"Asia/Seoul", "KR"},
    {"Asia/Kolkata", "IN"},
    {"Asia/Hong_Kong", "HK"},
    {"Asia/Singapore", "SG"},
    {"Asia/Taipei", "TW"},
    {"Asia/Kuala_Lumpur", "MY"},
    {"Asia/Jakarta", "ID"},
    {"Asia/Manila", "PH"},
    {"Asia/Bangkok", "TH"},
    {"Australia/Sydney", "AU"},
    {"Australia/Melbourne", "AU"},
    {"Australia/Brisbane", "AU"},
    {"Pacific/Auckland", "NZ"},
    {"Africa/Johannesburg", "ZA"}
  ]

  def load_movie(id_or_slug) do
    case fetch_movie_by_slug_or_id(id_or_slug) do
      {:ok, movie} -> load_movie_data(movie)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  def browser_region(params), do: browser_region_candidates(params)

  defp load_movie_data(movie) do
    movie = Repo.replica().preload(movie, :score_cache)
    movie = Map.merge(movie, Metrics.get_movie_aggregates(movie.id))

    current_version = MovieScoreCacheWorker.current_version()

    {scores, disparity} =
      if movie.score_cache && movie.score_cache.calculation_version == current_version do
        {build_display_scores(movie.score_cache),
         %{
           disparity_score: movie.score_cache.disparity_score,
           disparity_category: movie.score_cache.disparity_category
         }}
      else
        MovieScoreCacheWorker.new(%{"movie_id" => movie.id}, unique: [period: 60])
        |> Oban.insert()

        sd = MovieScoring.calculate_movie_scores(movie)
        {build_display_scores_from_data(sd), DisparityCalculator.calculate_all(sd)}
      end

    credits = Movies.get_movie_credits(movie.id)

    cast =
      credits |> Enum.filter(&(&1.credit_type == "cast")) |> Enum.sort_by(&(&1.cast_order || 999))

    crew = Enum.filter(credits, &(&1.credit_type == "crew"))
    directors = Enum.filter(crew, &(&1.job == "Director"))

    ratings = ExternalSources.get_movie_ratings(movie.id)
    festival_noms = Cultural.get_movie_all_festival_nominations(movie.id) || []
    canon_lists = Cultural.get_list_movies_for_movie(movie.id) || []
    keywords = Movies.get_movie_keywords(movie.id) || []
    videos = Movies.get_movie_videos(movie.id) || []
    production_companies = Movies.get_movie_production_companies(movie.id) || []
    release_dates = Movies.get_movie_release_dates(movie.id) || []

    key_collabs = MovieCollaborations.get_key_collaborations(cast, crew)

    related = MovieCollaborations.get_related_movies_by_collaboration(movie, cast, crew) || []

    director_other_films =
      case directors do
        [%{person: %{id: pid}} | _] -> fetch_director_filmography(pid, movie.id)
        _ -> []
      end

    availability = ShowV2Availability.availability_assigns(movie, Availability.default_region())

    data = %{
      movie: movie,
      scores: scores,
      disparity_data: disparity,
      cast: cast,
      crew: crew,
      directors: directors,
      ratings: ratings,
      festival_noms: festival_noms,
      canon_lists: canon_lists,
      keywords: keywords,
      videos: videos,
      production_companies: production_companies,
      release_dates: release_dates,
      key_collabs: key_collabs,
      related_movies: related,
      director_other_films: director_other_films
    }

    {:ok, Map.merge(data, availability)}
  end

  defp fetch_movie_by_slug_or_id(id_or_slug) do
    case Integer.parse(id_or_slug) do
      {id, ""} -> {:ok, Movies.get_movie!(id)}
      _ -> {:ok, Movies.get_movie_by_slug!(id_or_slug)}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp build_display_scores(cache) do
    %{
      mob: cache.mob_score || 0.0,
      critics: cache.critics_score || 0.0,
      festival_recognition: cache.festival_recognition_score || 0.0,
      time_machine: cache.time_machine_score || 0.0,
      auteurs: cache.auteurs_score || 0.0,
      box_office: cache.box_office_score || 0.0,
      overall: cache.overall_score || 0.0
    }
  end

  defp build_display_scores_from_data(sd) do
    c = sd.components

    %{
      mob: c.mob,
      critics: c.critics,
      festival_recognition: c.festival_recognition,
      time_machine: c.time_machine,
      auteurs: c.auteurs,
      box_office: c.box_office,
      overall: sd.overall_score
    }
  end

  defp fetch_director_filmography(person_id, exclude_movie_id) do
    from(c in Cinegraph.Movies.Credit,
      where:
        c.person_id == ^person_id and c.credit_type == "crew" and c.job == "Director" and
          c.movie_id != ^exclude_movie_id,
      join: m in assoc(c, :movie),
      preload: [movie: m],
      order_by: [desc: m.release_date],
      limit: 4
    )
    |> Repo.replica().all()
    |> Enum.map(& &1.movie)
  end

  defp browser_region_candidates(params) when is_map(params) do
    timezone_regions =
      params
      |> Map.get("browser_timezone")
      |> region_from_timezone()
      |> List.wrap()

    locale_regions =
      params
      |> browser_locales()
      |> Enum.flat_map(&regions_from_locale/1)

    (timezone_regions ++ locale_regions)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp browser_region_candidates(_), do: []

  defp browser_locales(params) do
    params
    |> Map.get("browser_locales")
    |> case do
      locales when is_list(locales) -> locales
      locale when is_binary(locale) -> String.split(locale, ",", trim: true)
      _ -> []
    end
    |> Kernel.++(List.wrap(Map.get(params, "browser_locale")))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp regions_from_locale(locale) when is_binary(locale) do
    parts = String.split(locale, ~r/[-_]/, trim: true)

    explicit_region =
      parts
      |> Enum.at(1)
      |> case do
        <<region::binary-size(2)>> -> String.upcase(region)
        _ -> nil
      end

    language_region =
      parts
      |> List.first()
      |> case do
        language when is_binary(language) ->
          Map.get(@language_region_fallbacks, String.downcase(language))

        _ ->
          nil
      end

    [explicit_region, language_region]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp regions_from_locale(_), do: []

  defp region_from_timezone(timezone) when is_binary(timezone) do
    Enum.find_value(@timezone_region_prefixes, fn {prefix, region} ->
      if String.starts_with?(timezone, prefix), do: region
    end)
  end

  defp region_from_timezone(_), do: nil
end
