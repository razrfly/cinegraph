defmodule Cinegraph.People do
  @moduledoc """
  The People context for managing movie cast and crew members.
  """

  import Ecto.Query, warn: false
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Person
  alias Cinegraph.Movies.Credit
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Metrics.PersonMetric

  @doc """
  Returns the list of people with optional pagination, filtering, and sorting.
  """
  def list_people(params \\ %{}) do
    Person
    |> filter_by_search(params["search"])
    |> filter_by_department(params["departments"])
    |> filter_by_gender(params["genders"])
    |> filter_by_age_range(params["age_min"], params["age_max"])
    |> filter_by_decade(params["birth_decade"])
    |> filter_by_status(params["status"])
    |> filter_by_nationality(params["nationality"])
    |> sort_people(params["sort_by"], params["sort_order"])
    |> paginate(params)
  end

  @doc """
  Returns people for the V2 index with card-ready aggregate fields.
  """
  def list_people_for_index(params \\ %{}) do
    base_query =
      Person
      |> filter_by_search(params["search"])
      |> filter_by_department(params["departments"])
      |> filter_by_gender(params["genders"])
      |> filter_by_age_range(params["age_min"], params["age_max"])
      |> filter_by_decade(params["birth_decade"])
      |> filter_by_status(params["status"])
      |> filter_by_nationality(params["nationality"])
      |> filter_by_adult_browse(params)

    if params["sort_by"] == "movie_count" do
      list_people_for_index_by_movie_count(base_query, params)
    else
      base_query
      |> with_quality_score()
      |> sort_people_for_index(params["sort_by"], params["sort_order"])
      |> select_index_card_fields()
      |> paginate(params)
    end
  end

  defp list_people_for_index_by_movie_count(query, params) do
    query
    |> with_quality_score()
    |> join(:left, [p], c in Credit, on: c.person_id == p.id)
    |> group_by([p, pm, c], [p.id, pm.score])
    |> sort_people_by_movie_count(params["sort_order"])
    |> select([p, pm, c], %{
      id: p.id,
      slug: p.slug,
      name: p.name,
      profile_path: p.profile_path,
      known_for_department: p.known_for_department,
      place_of_birth: p.place_of_birth,
      popularity: p.popularity,
      quality_score: pm.score,
      birthday: p.birthday,
      deathday: p.deathday,
      movie_count: count(fragment("DISTINCT ?", c.movie_id))
    })
    |> paginate(params)
  end

  defp select_index_card_fields(query) do
    select(query, [p, pm], %{
      id: p.id,
      slug: p.slug,
      name: p.name,
      profile_path: p.profile_path,
      known_for_department: p.known_for_department,
      place_of_birth: p.place_of_birth,
      popularity: p.popularity,
      quality_score: pm.score,
      birthday: p.birthday,
      deathday: p.deathday,
      movie_count:
        fragment(
          "(SELECT COUNT(DISTINCT mc.movie_id) FROM movie_credits mc WHERE mc.person_id = ?)",
          p.id
        )
    })
  end

  @doc """
  Returns the count of all people with optional filtering.
  Uses read replica for better load distribution.
  """
  def count_people(params \\ %{}) do
    Person
    |> filter_by_search(params["search"])
    |> filter_by_department(params["departments"])
    |> filter_by_gender(params["genders"])
    |> filter_by_age_range(params["age_min"], params["age_max"])
    |> filter_by_decade(params["birth_decade"])
    |> filter_by_status(params["status"])
    |> filter_by_nationality(params["nationality"])
    |> filter_by_adult_browse(params)
    |> Repo.replica().aggregate(:count, :id)
  end

  @doc """
  Gets a single person.
  Raises if the person does not exist.
  Uses read replica for better load distribution.
  """
  def get_person!(id) do
    Repo.replica().get!(Person, id)
  end

  @doc """
  Gets a single person.
  Returns nil if the person does not exist.
  Uses read replica for better load distribution.
  """
  def get_person(id) do
    Repo.replica().get(Person, id)
  end

  @doc """
  Gets a person by slug.
  Returns nil if not found.
  Uses read replica for better load distribution.
  """
  def get_person_by_slug(slug) do
    Repo.replica().get_by(Person, slug: slug)
  end

  @doc """
  Gets a person by TMDb ID.
  Returns nil if not found.
  Uses read replica for better load distribution.
  """
  def get_person_by_tmdb_id(tmdb_id) do
    Repo.replica().get_by(Person, tmdb_id: tmdb_id)
  end

  @doc """
  Gets a person by ID or slug.
  First tries to parse as integer ID, then falls back to slug lookup.
  Returns nil if not found.
  """
  def get_person_by_id_or_slug(id) when is_integer(id), do: get_person(id)

  def get_person_by_id_or_slug(id_or_slug) when is_binary(id_or_slug) do
    case Integer.parse(id_or_slug) do
      {id, ""} -> get_person(id)
      _ -> get_person_by_slug(id_or_slug)
    end
  end

  @doc """
  Gets a person with credits by ID or slug.
  First tries to parse as integer ID, then falls back to slug lookup.
  Returns nil if not found.
  """
  def get_person_with_credits_by_id_or_slug(id_or_slug) do
    person = get_person_by_id_or_slug(id_or_slug)
    if person, do: enrich_person_with_credits(person), else: nil
  end

  @doc """
  Gets a person with all their movies and credits preloaded.
  Raises if the person does not exist.
  Uses read replica for better load distribution.
  """
  def get_person_with_credits!(id) do
    Repo.replica().get!(Person, id)
    |> enrich_person_with_credits()
  end

  @doc """
  Gets a person with all their movies and credits preloaded.
  Returns nil if the person does not exist.
  Uses read replica for better load distribution.
  """
  def get_person_with_credits(id) do
    case Repo.replica().get(Person, id) do
      nil -> nil
      person -> enrich_person_with_credits(person)
    end
  end

  defp enrich_person_with_credits(person) do
    # Get all credits for this person with movie details
    # Uses read replica for better load distribution
    credits =
      Credit
      |> where([c], c.person_id == ^person.id)
      |> join(:inner, [c], m in Movie, on: c.movie_id == m.id)
      |> preload([c, m], movie: m)
      |> order_by([c, m], desc: m.release_date)
      |> Repo.replica().all()

    # Separate cast and crew credits
    cast_credits = Enum.filter(credits, &(&1.credit_type == "cast"))
    crew_credits = Enum.filter(credits, &(&1.credit_type == "crew"))

    # Group crew credits by department
    crew_by_department = Enum.group_by(crew_credits, & &1.department)

    # Find frequent collaborators
    collaborators = find_frequent_collaborators(person.id, credits)

    person
    |> Map.put(:cast_credits, cast_credits)
    |> Map.put(:crew_credits, crew_credits)
    |> Map.put(:crew_by_department, crew_by_department)
    |> Map.put(:collaborators, collaborators)
    |> Map.put(:total_movies, length(Enum.uniq_by(credits, & &1.movie_id)))
  end

  @doc """
  Finds people who frequently work with the given person.
  """
  def find_frequent_collaborators(person_id, credits \\ nil) do
    # If credits aren't provided, fetch them
    credits = credits || get_person_credits(person_id)

    movie_ids = Enum.map(credits, & &1.movie_id) |> Enum.uniq()

    # Find all other people who worked on the same movies
    # Uses read replica for better load distribution
    collaborator_credits =
      Credit
      |> where([c], c.movie_id in ^movie_ids and c.person_id != ^person_id)
      |> join(:inner, [c], p in Person, on: c.person_id == p.id)
      |> preload([c, p], person: p)
      |> Repo.replica().all()

    # Group by person and count collaborations
    collaborator_credits
    |> Enum.group_by(& &1.person_id)
    |> Enum.map(fn {_person_id, person_credits} ->
      person = hd(person_credits).person
      movies_together = Enum.map(person_credits, & &1.movie_id) |> Enum.uniq() |> length()

      %{
        person: person,
        movies_together: movies_together,
        roles:
          Enum.map(person_credits, fn c ->
            if c.credit_type == "cast", do: "Actor", else: c.job
          end)
          |> Enum.uniq()
      }
    end)
    |> Enum.sort_by(& &1.movies_together, :desc)
    |> Enum.take(20)
  end

  @doc """
  Gets all credits for a person.
  Uses read replica for better load distribution.
  """
  def get_person_credits(person_id) do
    Credit
    |> where([c], c.person_id == ^person_id)
    |> preload(:movie)
    |> Repo.replica().all()
  end

  @doc """
  Searches for people by name with optimized performance.
  Uses prefix matching first for better index usage, then falls back to contains.
  """
  def search_people(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    # Optimize search for better performance
    # Use prefix matching first, then fallback to contains
    prefix_term = "#{String.downcase(query)}%"
    contains_term = "%#{String.downcase(query)}%"

    # Try prefix match first (uses index if available)
    prefix_results =
      Person
      |> where([p], fragment("LOWER(?) LIKE ?", p.name, ^prefix_term))
      |> order_by([p], desc: p.popularity)
      |> limit(^limit)
      |> select([p], %{
        id: p.id,
        slug: p.slug,
        name: p.name,
        profile_path: p.profile_path,
        known_for_department: p.known_for_department,
        popularity: p.popularity
      })
      |> Repo.replica().all()

    # If we don't have enough results, do a contains search
    if length(prefix_results) < div(limit, 2) do
      Person
      |> where([p], fragment("LOWER(?) LIKE ?", p.name, ^contains_term))
      |> where([p], p.id not in ^Enum.map(prefix_results, & &1.id))
      |> order_by([p], desc: p.popularity)
      |> limit(^(limit - length(prefix_results)))
      |> select([p], %{
        id: p.id,
        slug: p.slug,
        name: p.name,
        profile_path: p.profile_path,
        known_for_department: p.known_for_department,
        popularity: p.popularity
      })
      |> Repo.replica().all()
      |> then(&(prefix_results ++ &1))
    else
      prefix_results
    end
  end

  @doc """
  Gets multiple people by their IDs.
  """
  def get_people_by_ids(ids) when is_list(ids) do
    Person
    |> where([p], p.id in ^ids)
    |> order_by([p], desc: p.popularity)
    |> Repo.replica().all()
  end

  def get_people_by_ids(_), do: []

  @doc """
  Gets all available departments for filtering.
  """
  def get_departments do
    Person
    |> where([p], not is_nil(p.known_for_department))
    |> select([p], p.known_for_department)
    |> distinct(true)
    |> order_by([p], p.known_for_department)
    |> Repo.replica().all()
  end

  @doc """
  Gets available birth decades for filtering.
  """
  def get_birth_decades do
    Person
    |> where([p], not is_nil(p.birthday))
    |> select([p], fragment("EXTRACT(decade FROM ?) * 10", p.birthday))
    |> distinct(true)
    |> order_by([p], fragment("EXTRACT(decade FROM ?) * 10", p.birthday))
    |> Repo.replica().all()
    |> Enum.map(&normalize_birth_decade/1)
  end

  defp normalize_birth_decade(%Decimal{} = decade), do: Decimal.to_integer(decade)
  defp normalize_birth_decade(decade) when is_integer(decade), do: decade
  defp normalize_birth_decade(decade) when is_float(decade), do: trunc(decade)

  @doc """
  Gets available nationalities/places of birth for filtering.
  """
  def get_nationalities do
    Person
    |> where([p], not is_nil(p.place_of_birth) and p.place_of_birth != "")
    |> select([p], p.place_of_birth)
    |> distinct(true)
    |> order_by([p], p.place_of_birth)
    |> limit(100)
    |> Repo.replica().all()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Gets career statistics for a person.
  """
  def get_career_stats(person_id) do
    credits = get_person_credits(person_id)

    movies = Enum.map(credits, & &1.movie) |> Enum.uniq_by(& &1.id)

    %{
      total_movies: length(movies),
      as_actor: Enum.count(credits, &(&1.credit_type == "cast")),
      as_crew: Enum.count(credits, &(&1.credit_type == "crew")),
      departments:
        credits
        |> Enum.filter(&(&1.credit_type == "crew"))
        |> Enum.map(& &1.department)
        |> Enum.uniq()
        |> Enum.reject(&is_nil/1),
      years_active: calculate_years_active(movies),
      total_revenue: calculate_total_revenue(movies),
      average_rating: calculate_average_rating(movies)
    }
  end

  defp calculate_years_active(movies) do
    dates =
      movies
      |> Enum.map(& &1.release_date)
      |> Enum.reject(&is_nil/1)

    if length(dates) > 0 do
      min_date = Enum.min(dates, Date)
      max_date = Enum.max(dates, Date)

      %{
        first_movie: min_date,
        latest_movie: max_date,
        years: max_date.year - min_date.year
      }
    else
      %{first_movie: nil, latest_movie: nil, years: 0}
    end
  end

  # #913 PR A pt 2: was iterating movies and reading movie.tmdb_data["revenue"]
  # per row. Now a single query against external_metrics. The four
  # `normalize_revenue/1` clauses that handled int/float/string/nil JSONB
  # values are gone — external_metrics stores `value` as float, so the only
  # transformation needed is `trunc(sum)`.
  defp calculate_total_revenue(movies) do
    movie_ids = movies |> Enum.map(& &1.id) |> Enum.uniq()

    if movie_ids == [] do
      0
    else
      sum =
        Repo.replica().one(
          from em in Cinegraph.Movies.ExternalMetric,
            where:
              em.movie_id in ^movie_ids and
                em.source == "tmdb" and
                em.metric_type == "revenue_worldwide",
            select: sum(em.value)
        )

      case sum do
        nil -> 0
        s when is_number(s) -> trunc(s)
      end
    end
  end

  @doc """
  Builds a `%{movie_id => revenue_int}` map for the given movie IDs.

  Reads TMDb `revenue_worldwide` rows from `external_metrics` so templates
  can render per-credit revenue without touching `tmdb_data` JSONB.
  """
  def revenue_map_for_movie_ids([]), do: %{}

  def revenue_map_for_movie_ids(movie_ids) when is_list(movie_ids) do
    ids = movie_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ids == [] do
      %{}
    else
      from(em in Cinegraph.Movies.ExternalMetric,
        where:
          em.movie_id in ^ids and
            em.source == "tmdb" and
            em.metric_type == "revenue_worldwide",
        distinct: em.movie_id,
        order_by: [asc: em.movie_id, desc: em.fetched_at, desc: em.id],
        select: {em.movie_id, em.value}
      )
      |> Repo.replica().all()
      |> Map.new(fn {id, value} ->
        revenue = if is_number(value), do: trunc(value), else: 0
        {id, revenue}
      end)
    end
  end

  defp calculate_average_rating(movies) do
    ratings =
      movies
      |> Enum.map(&Movie.vote_average/1)
      |> Enum.reject(&is_nil/1)

    if length(ratings) > 0 do
      Float.round(Enum.sum(ratings) / length(ratings), 1)
    else
      nil
    end
  end

  # Filter helper functions
  defp filter_by_search(query, nil), do: query
  defp filter_by_search(query, ""), do: query

  defp filter_by_search(query, search_term) do
    search_pattern = "%#{search_term}%"
    where(query, [p], ilike(p.name, ^search_pattern))
  end

  defp filter_by_department(query, nil), do: query
  defp filter_by_department(query, []), do: query

  defp filter_by_department(query, departments) when is_list(departments) do
    where(query, [p], p.known_for_department in ^departments)
  end

  defp filter_by_department(query, department) when is_binary(department) do
    where(query, [p], p.known_for_department == ^department)
  end

  defp filter_by_gender(query, nil), do: query
  defp filter_by_gender(query, []), do: query

  defp filter_by_gender(query, genders) when is_list(genders) do
    gender_ints = Enum.map(genders, &parse_gender/1)
    where(query, [p], p.gender in ^gender_ints)
  end

  defp filter_by_gender(query, gender) when is_binary(gender) do
    gender_int = parse_gender(gender)
    where(query, [p], p.gender == ^gender_int)
  end

  # Female
  defp parse_gender("1"), do: 1
  # Male
  defp parse_gender("2"), do: 2
  # Non-binary
  defp parse_gender("3"), do: 3
  defp parse_gender("female"), do: 1
  defp parse_gender("male"), do: 2
  defp parse_gender("non-binary"), do: 3
  defp parse_gender(_), do: nil

  defp filter_by_age_range(query, nil, nil), do: query

  defp filter_by_age_range(query, age_min, age_max) do
    current_date = Date.utc_today()

    query =
      if age_min do
        with {min_age, _} <- Integer.parse(age_min) do
          max_birth_date =
            safe_date_new(current_date.year - min_age, current_date.month, current_date.day)

          where(query, [p], is_nil(p.birthday) or p.birthday <= ^max_birth_date)
        else
          _ -> query
        end
      else
        query
      end

    if age_max do
      with {max_age, _} <- Integer.parse(age_max) do
        min_birth_date =
          safe_date_new(current_date.year - max_age, current_date.month, current_date.day)

        where(query, [p], not is_nil(p.birthday) and p.birthday >= ^min_birth_date)
      else
        _ -> query
      end
    else
      query
    end
  end

  # Helper function to safely create dates, clamping invalid days to the month's last day
  defp safe_date_new(year, month, day) do
    case Date.new(year, month, day) do
      {:ok, date} ->
        date

      {:error, _} ->
        last_day = Date.days_in_month(Date.new!(year, month, 1))
        Date.new!(year, month, min(day, last_day))
    end
  end

  defp filter_by_decade(query, nil), do: query

  defp filter_by_decade(query, decade) do
    with {decade_year, _} <- Integer.parse(decade) do
      start_year = decade_year
      end_year = decade_year + 9
      start_date = Date.new!(start_year, 1, 1)
      end_date = Date.new!(end_year, 12, 31)

      where(
        query,
        [p],
        not is_nil(p.birthday) and
          p.birthday >= ^start_date and
          p.birthday <= ^end_date
      )
    else
      _ -> query
    end
  end

  defp filter_by_status(query, nil), do: query
  defp filter_by_status(query, []), do: query

  defp filter_by_status(query, status_filters) when is_list(status_filters) do
    Enum.reduce(status_filters, query, &apply_status_filter/2)
  end

  defp filter_by_status(query, status) when is_binary(status) do
    apply_status_filter(status, query)
  end

  defp apply_status_filter("living", query) do
    where(query, [p], is_nil(p.deathday))
  end

  defp apply_status_filter("deceased", query) do
    where(query, [p], not is_nil(p.deathday))
  end

  defp apply_status_filter("has_biography", query) do
    where(query, [p], not is_nil(p.biography) and p.biography != "")
  end

  defp apply_status_filter("has_image", query) do
    where(query, [p], not is_nil(p.profile_path))
  end

  defp apply_status_filter(_, query), do: query

  defp filter_by_nationality(query, nil), do: query
  defp filter_by_nationality(query, ""), do: query

  defp filter_by_nationality(query, nationality) do
    search_pattern = "%#{nationality}%"
    where(query, [p], ilike(p.place_of_birth, ^search_pattern))
  end

  defp filter_by_adult_browse(query, params) do
    cond do
      include_adult?(params["include_adult"]) ->
        query

      has_search?(params["search"]) ->
        query

      true ->
        where(query, [p], p.adult == false or is_nil(p.adult))
    end
  end

  defp include_adult?(value) when value in [true, "true", "1", 1, "on"], do: true
  defp include_adult?(_), do: false

  defp has_search?(value) when is_binary(value), do: String.trim(value) != ""
  defp has_search?(_), do: false

  defp with_quality_score(query) do
    join(query, :left, [p], pm in PersonMetric,
      on: pm.person_id == p.id and pm.metric_type == "quality_score"
    )
  end

  defp sort_people(query, nil, _), do: order_by(query, desc: :popularity)
  defp sort_people(query, "", _), do: order_by(query, desc: :popularity)

  defp sort_people(query, sort_by, sort_order) do
    direction = if sort_order == "desc", do: :desc, else: :asc

    case sort_by do
      "name" ->
        order_by(query, [{^direction, :name}])

      "popularity" ->
        order_by(query, [{^direction, :popularity}])

      "birthday" ->
        if direction == :asc do
          # For ascending birthday, we want oldest first (earliest dates)
          order_by(query, [p], [{^direction, fragment("COALESCE(?, '1900-01-01')", p.birthday)}])
        else
          # For descending birthday, we want youngest first (latest dates)
          order_by(query, [p], [{^direction, fragment("COALESCE(?, '2100-01-01')", p.birthday)}])
        end

      "recently_added" ->
        order_by(query, [{^direction, :inserted_at}])

      "movie_count" ->
        # Join with credits and count distinct movies
        query
        |> join(:left, [p], c in Credit, on: c.person_id == p.id)
        |> group_by([p], p.id)
        |> order_by([p, c], [{^direction, count(fragment("DISTINCT ?", c.movie_id))}])
        |> select([p, c], p)

      _ ->
        order_by(query, desc: :popularity)
    end
  end

  defp sort_people_for_index(query, nil, _), do: sort_people_for_index(query, "relevance", "desc")
  defp sort_people_for_index(query, "", _), do: sort_people_for_index(query, "relevance", "desc")

  defp sort_people_for_index(query, sort_by, sort_order) do
    direction = if sort_order == "desc", do: :desc, else: :asc

    case sort_by do
      "relevance" ->
        order_by(query, [p, pm],
          desc_nulls_last: pm.score,
          desc_nulls_last: p.popularity,
          asc: p.name
        )

      "name" ->
        order_by(query, [p], [{^direction, p.name}])

      "popularity" ->
        order_by(query, [p], [{^direction, p.popularity}])

      "birthday" ->
        if direction == :asc do
          order_by(query, [p], [
            {^direction, fragment("COALESCE(?, '1900-01-01')", p.birthday)}
          ])
        else
          order_by(query, [p], [
            {^direction, fragment("COALESCE(?, '2100-01-01')", p.birthday)}
          ])
        end

      "recently_added" ->
        order_by(query, [p], [{^direction, p.inserted_at}])

      _ ->
        sort_people_for_index(query, "relevance", "desc")
    end
  end

  defp sort_people_by_movie_count(query, sort_order) do
    direction = if sort_order == "asc", do: :asc, else: :desc
    order_by(query, [_p, _pm, c], [{^direction, count(fragment("DISTINCT ?", c.movie_id))}])
  end

  defp paginate(query, %{"page" => page, "per_page" => per_page}) do
    with {page_num, _} <- Integer.parse(page || "1"),
         {per_page_num, _} <- Integer.parse(per_page || "50") do
      page_num = max(page_num, 1)
      per_page_num = per_page_num |> min(100) |> max(1)

      query
      |> limit(^per_page_num)
      |> offset(^((page_num - 1) * per_page_num))
      |> Repo.replica().all()
    else
      _ -> paginate(query, %{})
    end
  end

  defp paginate(query, _params) do
    query
    |> limit(50)
    |> Repo.replica().all()
  end
end
