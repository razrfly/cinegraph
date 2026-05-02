defmodule Cinegraph.Movies.SearchTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Festivals.FestivalOrganization

  alias Cinegraph.Movies.{
    Credit,
    DiscoveryRankings,
    ExternalMetric,
    Genre,
    Movie,
    MovieScoreCache,
    MovieList,
    Person,
    ProductionCompany,
    Search
  }

  alias Cinegraph.Movies.Query.Params
  alias Cinegraph.Workers.MovieScoreCacheWorker

  setup do
    assert {:ok, _} = Cachex.clear(:movies_cache)
    :ok
  end

  describe "search_movies/1 genre filters" do
    test "single genre returns movies with that genre" do
      drama = insert_genre!("Drama")
      comedy = insert_genre!("Comedy")

      drama_only = insert_movie!("Genre Single Drama")
      comedy_only = insert_movie!("Genre Single Comedy")

      add_genres!(drama_only, [drama])
      add_genres!(comedy_only, [comedy])

      assert {:ok, {movies, meta}} = search_by_genres([drama.id])
      assert movie_titles(movies) == ["Genre Single Drama"]
      assert meta.total_count == 1
    end

    test "stacked genres return only movies with all selected genres" do
      drama = insert_genre!("Drama")
      comedy = insert_genre!("Comedy")

      _drama_only =
        insert_movie!("Genre Stack Drama")
        |> add_genres!([drama])

      _comedy_only =
        insert_movie!("Genre Stack Comedy")
        |> add_genres!([comedy])

      _both =
        insert_movie!("Genre Stack Both")
        |> add_genres!([drama, comedy])

      assert {:ok, {movies, meta}} = search_by_genres([drama.id, comedy.id])
      assert {:ok, count} = count_by_genres([drama.id, comedy.id])

      assert movie_titles(movies) == ["Genre Stack Both"]
      assert meta.total_count == 1
      assert count == meta.total_count
    end

    test "comma-delimited genre slugs resolve to genre IDs" do
      drama = insert_genre!("Drama")
      comedy = insert_genre!("Comedy")

      _drama_only =
        insert_movie!("Genre Slug Drama")
        |> add_genres!([drama])

      _both =
        insert_movie!("Genre Slug Both")
        |> add_genres!([drama, comedy])

      assert {:ok, {movies, meta}} =
               Search.search_movies(%{
                 "genres" => "#{Genre.slug(comedy)},#{Genre.slug(drama)}",
                 "per_page" => "10",
                 "sort" => "title_asc"
               })

      assert movie_titles(movies) == ["Genre Slug Both"]
      assert meta.total_count == 1
    end

    test "unknown genre slugs normalize away safely" do
      drama = insert_genre!("Drama")

      _movie =
        insert_movie!("Genre Unknown Slug Drama")
        |> add_genres!([drama])

      assert {:ok, {movies, meta}} =
               Search.search_movies(%{
                 "genres" => "not-a-real-genre,#{Genre.slug(drama)}",
                 "per_page" => "10",
                 "sort" => "title_asc"
               })

      assert movie_titles(movies) == ["Genre Unknown Slug Drama"]
      assert meta.total_count == 1
    end

    test "duplicate genre params do not make the all-genres match impossible" do
      drama = insert_genre!("Drama")
      comedy = insert_genre!("Comedy")

      _both =
        insert_movie!("Genre Duplicate Both")
        |> add_genres!([drama, comedy])

      assert {:ok, {movies, meta}} = search_by_genres([drama.id, comedy.id, comedy.id])
      assert movie_titles(movies) == ["Genre Duplicate Both"]
      assert meta.total_count == 1
    end

    test "malformed and blank genre params normalize away safely" do
      drama = insert_genre!("Drama")

      _movie =
        insert_movie!("Genre Malformed Drama")
        |> add_genres!([drama])

      assert {:ok, {movies, meta}} =
               Search.search_movies(%{
                 "genres[]" => ["not-a-genre", "", to_string(drama.id)],
                 "per_page" => "10",
                 "sort" => "title_asc"
               })

      assert movie_titles(movies) == ["Genre Malformed Drama"]
      assert meta.total_count == 1
    end
  end

  describe "search_movies/1 CineGraph scoreability sorting" do
    test "score sort ranks scoreable movies before insufficient-evidence movies" do
      scoreable = insert_movie!("Scoreability Sort Strong", release_date: ~D[2020-01-01])
      limited = insert_movie!("Scoreability Sort Limited", release_date: ~D[2021-01-01])
      insufficient = insert_movie!("Scoreability Sort Sparse", release_date: ~D[2022-01-01])

      insert_score_cache!(scoreable, 8.0, [8.0, 7.0, 6.0, 5.0, 4.0, 3.0])
      insert_score_cache!(limited, 7.0, [7.0, 6.0, 0.0, 0.0, 0.0, 0.0])
      insert_score_cache!(insufficient, 9.9, [9.9, 0.0, 0.0, 0.0, 0.0, 0.0])

      assert {:ok, {movies, _meta}} =
               Search.search_movies_uncached(%{
                 "sort" => "score_desc",
                 "per_page" => "10"
               })

      assert movie_titles(movies) == [
               "Scoreability Sort Strong",
               "Scoreability Sort Limited",
               "Scoreability Sort Sparse"
             ]

      assert Enum.map(movies, & &1.scoreability_state) == [
               "scoreable",
               "limited",
               "insufficient_evidence"
             ]

      assert Enum.map(movies, & &1.overall_score) == [8.0, 7.0, nil]
    end

    test "plain score sort paginates across the scoreable and insufficient boundary" do
      first = insert_movie!("Scoreability Page First", release_date: ~D[2020-01-01])
      second = insert_movie!("Scoreability Page Second", release_date: ~D[2021-01-01])
      sparse_newer = insert_movie!("Scoreability Page Sparse Newer", release_date: ~D[2024-01-01])
      sparse_older = insert_movie!("Scoreability Page Sparse Older", release_date: ~D[2023-01-01])

      insert_score_cache!(first, 9.0, [9.0, 9.0, 9.0, 9.0, 9.0, 9.0])
      insert_score_cache!(second, 8.0, [8.0, 8.0, 8.0, 8.0, 8.0, 8.0])
      insert_score_cache!(sparse_newer, 10.0, [10.0, 0.0, 0.0, 0.0, 0.0, 0.0])
      insert_score_cache!(sparse_older, 9.5, [9.5, 0.0, 0.0, 0.0, 0.0, 0.0])

      assert {:ok, {page_1, meta_1}} =
               Search.search_movies_uncached(%{
                 "sort" => "score_desc",
                 "per_page" => "3",
                 "page" => "1"
               })

      assert {:ok, {page_2, meta_2}} =
               Search.search_movies_uncached(%{
                 "sort" => "score_desc",
                 "per_page" => "3",
                 "page" => "2"
               })

      assert movie_titles(page_1) == [
               first.title,
               second.title,
               sparse_newer.title
             ]

      assert movie_titles(page_2) == [sparse_older.title]
      assert meta_1.total_count == 4
      assert meta_1.total_pages == 2
      assert meta_2.current_page == 2
    end

    test "ascending score sort keeps insufficient-evidence movies after scoreable movies" do
      high = insert_movie!("Scoreability Asc High", release_date: ~D[2020-01-01])
      low = insert_movie!("Scoreability Asc Low", release_date: ~D[2021-01-01])
      insufficient = insert_movie!("Scoreability Asc Sparse", release_date: ~D[2022-01-01])

      insert_score_cache!(high, 9.0, [9.0, 9.0, 9.0, 9.0, 9.0, 9.0])
      insert_score_cache!(low, 3.0, [3.0, 3.0, 0.0, 0.0, 0.0, 0.0])
      insert_score_cache!(insufficient, 1.0, [1.0, 0.0, 0.0, 0.0, 0.0, 0.0])

      assert {:ok, {movies, _meta}} =
               Search.search_movies_uncached(%{
                 "sort" => "score_asc",
                 "per_page" => "10"
               })

      assert movie_titles(movies) == [
               low.title,
               high.title,
               insufficient.title
             ]

      assert List.last(movies).scoreability_state == "insufficient_evidence"
    end

    test "filtered score sorts stay on the generic filter path" do
      drama = insert_genre!("Scoreability Filter Drama")
      comedy = insert_genre!("Scoreability Filter Comedy")

      drama_movie =
        insert_movie!("Scoreability Filter Match", release_date: ~D[2020-01-01])
        |> add_genres!([drama])

      _comedy_movie =
        insert_movie!("Scoreability Filter Miss", release_date: ~D[2020-01-01])
        |> add_genres!([comedy])

      insert_score_cache!(drama_movie, 8.0, [8.0, 8.0, 8.0, 8.0, 8.0, 8.0])

      assert {:ok, {movies, meta}} =
               Search.search_movies_uncached(%{
                 "sort" => "score_desc",
                 "genres[]" => [to_string(drama.id)],
                 "per_page" => "10"
               })

      assert movie_titles(movies) == [drama_movie.title]
      assert meta.total_count == 1
    end
  end

  describe "search_movies/1 default discovery rankings" do
    test "default browse uses the materialized rankings ordering and count" do
      lower = insert_movie!("MV Lower Score", release_date: ~D[2024-01-01])
      higher = insert_movie!("MV Higher Score", release_date: ~D[2024-01-01])

      add_tmdb_metrics!(lower, popularity: 1.0, votes: 10.0, rating: 5.0)
      add_tmdb_metrics!(higher, popularity: 500.0, votes: 10_000.0, rating: 8.0)

      DiscoveryRankings.refresh(concurrently: false)

      assert {:ok, {movies, meta}} = Search.search_movies_uncached(%{"per_page" => "10"})

      assert movie_titles(movies) == ["MV Higher Score", "MV Lower Score"]
      assert meta.total_count == 2
      assert meta.total_pages == 1
    end

    test "default browse count comes from the materialized view" do
      _refreshed_movie = insert_movie!("MV Count Refreshed")
      DiscoveryRankings.refresh(concurrently: false)

      _unrefreshed_movie = insert_movie!("MV Count Not Yet Refreshed")

      assert {:ok, count} = Search.count_movies(%{})
      assert count == 1
    end

    test "non-default filters fall back to generic search semantics" do
      _refreshed_movie = insert_movie!("MV Search Refreshed")
      DiscoveryRankings.refresh(concurrently: false)

      _unrefreshed_match = insert_movie!("MV Search Unrefreshed Match")

      assert {:ok, {movies, meta}} =
               Search.search_movies_uncached(%{
                 "search" => "Unrefreshed Match",
                 "per_page" => "10"
               })

      assert movie_titles(movies) == ["MV Search Unrefreshed Match"]
      assert meta.total_count == 1
    end
  end

  describe "filter URL value normalization" do
    test "festival slugs normalize to festival IDs" do
      festival = insert_festival!("BAFTA Test")

      assert {:ok, params} = Params.validate(%{"festivals" => festival.slug})
      assert params.festivals == [festival.id]
    end

    test "list slugs normalize to canonical source keys" do
      list = insert_movie_list!("Slug List Test")

      assert {:ok, params} = Params.validate(%{"lists" => list.slug})
      assert params.lists == [list.source_key]
    end

    test "person slugs normalize to person IDs" do
      person = insert_person!("Slug Person Test")

      assert {:ok, params} = Params.validate(%{"people" => person.slug})
      assert params.people_ids == [person.id]
    end

    test "people slugs do not overwrite explicit people IDs" do
      slug_person = insert_person!("Slug Person Test")
      id_person = insert_person!("Explicit Person Test")

      assert {:ok, params} =
               Params.validate(%{
                 "people" => slug_person.slug,
                 "people_ids" => to_string(id_person.id)
               })

      assert params.people_ids == [id_person.id]
    end

    test "people_match accepts all mode" do
      assert {:ok, params} = Params.validate(%{"people_match" => "all"})
      assert params.people_match == "all"
    end

    test "company slugs normalize to production company IDs" do
      company = insert_company!("Slug Company Test")

      assert {:ok, params} = Params.validate(%{"companies" => company.slug})
      assert params.production_company_ids == [company.id]
    end

    test "unknown company slugs normalize away safely" do
      assert {:ok, params} = Params.validate(%{"companies" => "not-a-real-company"})
      assert params.production_company_ids == []
    end

    test "production_company_ids take precedence over company slugs" do
      slug_company = insert_company!("Slug Company Test")
      id_company = insert_company!("Explicit Company Test")

      assert {:ok, params} =
               Params.validate(%{
                 "companies" => slug_company.slug,
                 "production_company_ids" => to_string(id_company.id)
               })

      assert params.production_company_ids == [id_company.id]
    end

    test "unknown list slugs normalize away safely" do
      assert {:ok, params} = Params.validate(%{"lists" => "not-a-real-list"})
      assert params.lists == []
    end
  end

  describe "search_movies/1 people filters" do
    test "default people matching returns movies with any selected person" do
      amanda = insert_person!("Amanda Any Test")
      jeffrey = insert_person!("Jeffrey Any Test")

      amanda_only =
        insert_movie!("People Any Amanda")
        |> add_credit!(amanda)

      jeffrey_only =
        insert_movie!("People Any Jeffrey")
        |> add_credit!(jeffrey)

      together =
        insert_movie!("People Any Together")
        |> add_credit!(amanda)
        |> add_credit!(jeffrey)

      assert {:ok, {movies, meta}} =
               Search.search_movies(%{
                 "people" => "#{amanda.slug},#{jeffrey.slug}",
                 "per_page" => "10",
                 "sort" => "title_asc"
               })

      assert movie_titles(movies) == [
               amanda_only.title,
               jeffrey_only.title,
               together.title
             ]

      assert meta.total_count == 3
    end

    test "all people matching returns only movies with every selected person" do
      amanda = insert_person!("Amanda All Test")
      jeffrey = insert_person!("Jeffrey All Test")

      _amanda_only =
        insert_movie!("People All Amanda")
        |> add_credit!(amanda)

      _jeffrey_only =
        insert_movie!("People All Jeffrey")
        |> add_credit!(jeffrey)

      together =
        insert_movie!("People All Together")
        |> add_credit!(amanda)
        |> add_credit!(jeffrey)

      assert {:ok, {movies, meta}} =
               Search.search_movies(%{
                 "people" => "#{amanda.slug},#{jeffrey.slug}",
                 "people_match" => "all",
                 "per_page" => "10",
                 "sort" => "title_asc"
               })

      assert movie_titles(movies) == [together.title]
      assert meta.total_count == 1
    end
  end

  describe "search_movies/1 production company filters" do
    test "single company returns movies with that company" do
      a24 = insert_company!("A24 Search")
      neon = insert_company!("Neon Search")

      _a24_movie =
        insert_movie!("Company Single A24")
        |> add_companies!([a24])

      _neon_movie =
        insert_movie!("Company Single Neon")
        |> add_companies!([neon])

      assert {:ok, {movies, meta}} =
               Search.search_movies(%{
                 "companies" => to_string(a24.id),
                 "per_page" => "10",
                 "sort" => "title_asc"
               })

      assert movie_titles(movies) == ["Company Single A24"]
      assert meta.total_count == 1
    end

    test "company filter bypasses default browse optimization" do
      a24 = insert_company!("A24 Default Browse")
      _match = insert_movie!("Company Default Browse A24") |> add_companies!([a24])
      _miss = insert_movie!("Company Default Browse Outside")

      assert {:ok, {movies, meta}} =
               Search.search_movies(%{
                 "companies" => to_string(a24.id),
                 "per_page" => "10"
               })

      assert movie_titles(movies) == ["Company Default Browse A24"]
      assert meta.total_count == 1
    end

    test "multiple companies use any semantics" do
      a24 = insert_company!("A24 Any")
      neon = insert_company!("Neon Any")
      searchlight = insert_company!("Searchlight Any")

      _a24_movie =
        insert_movie!("Company Any A24")
        |> add_companies!([a24])

      _neon_movie =
        insert_movie!("Company Any Neon")
        |> add_companies!([neon])

      _searchlight_movie =
        insert_movie!("Company Any Searchlight")
        |> add_companies!([searchlight])

      assert {:ok, {movies, meta}} =
               Search.search_movies(%{
                 "companies" => "#{a24.slug},#{neon.slug}",
                 "per_page" => "10",
                 "sort" => "title_asc"
               })

      assert movie_titles(movies) == ["Company Any A24", "Company Any Neon"]
      assert meta.total_count == 2
    end

    test "malformed and blank company params normalize away safely" do
      a24 = insert_company!("A24 Malformed")

      _movie =
        insert_movie!("Company Malformed A24")
        |> add_companies!([a24])

      assert {:ok, {movies, meta}} =
               Search.search_movies(%{
                 "companies[]" => ["not-a-company", "", to_string(a24.id)],
                 "per_page" => "10",
                 "sort" => "title_asc"
               })

      assert movie_titles(movies) == ["Company Malformed A24"]
      assert meta.total_count == 1
    end

    test "count matches filtered search meta" do
      company = insert_company!("Company Count")

      _match =
        insert_movie!("Company Count Match")
        |> add_companies!([company])

      _miss = insert_movie!("Company Count Miss")

      params = %{
        "companies" => company.slug,
        "per_page" => "10",
        "sort" => "title_asc"
      }

      assert {:ok, {_movies, meta}} = Search.search_movies(params)
      assert {:ok, count} = Search.count_movies(params)
      assert count == meta.total_count
    end

    test "company filter composes with search and sort" do
      company = insert_company!("Company Compose")

      _match =
        insert_movie!("Company Compose Moonlight")
        |> add_companies!([company])

      _company_nonmatch =
        insert_movie!("Company Compose Other")
        |> add_companies!([company])

      _search_nonmatch = insert_movie!("Company Compose Moonlight Outside")

      assert {:ok, {movies, meta}} =
               Search.search_movies(%{
                 "companies" => company.slug,
                 "search" => "Moonlight",
                 "per_page" => "10",
                 "sort" => "title_asc"
               })

      assert movie_titles(movies) == ["Company Compose Moonlight"]
      assert meta.total_count == 1
    end
  end

  defp search_by_genres(genre_ids) do
    genre_ids
    |> genre_params()
    |> Search.search_movies()
  end

  defp count_by_genres(genre_ids) do
    genre_ids
    |> genre_params()
    |> Search.count_movies()
  end

  defp genre_params(genre_ids) do
    %{
      "genres[]" => Enum.map(genre_ids, &to_string/1),
      "per_page" => "10",
      "sort" => "title_asc"
    }
  end

  defp insert_movie!(title, attrs \\ []) do
    release_date = Keyword.get(attrs, :release_date, ~D[2024-01-01])

    %Movie{}
    |> Movie.changeset(%{
      tmdb_id: System.unique_integer([:positive]),
      title: title,
      original_title: title,
      release_date: release_date
    })
    |> Repo.insert!()
  end

  defp add_tmdb_metrics!(movie, popularity: popularity, votes: votes, rating: rating) do
    fetched_at = DateTime.utc_now() |> DateTime.truncate(:second)

    [
      {"popularity_score", popularity},
      {"rating_votes", votes},
      {"rating_average", rating}
    ]
    |> Enum.each(fn {metric_type, value} ->
      Repo.insert!(%ExternalMetric{
        movie_id: movie.id,
        source: "tmdb",
        metric_type: metric_type,
        value: value,
        fetched_at: fetched_at
      })
    end)

    movie
  end

  defp insert_score_cache!(movie, overall_score, [
         mob,
         critics,
         festival,
         time_machine,
         auteurs,
         box_office
       ]) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%MovieScoreCache{
      movie_id: movie.id,
      mob_score: mob,
      critics_score: critics,
      festival_recognition_score: festival,
      time_machine_score: time_machine,
      auteurs_score: auteurs,
      box_office_score: box_office,
      overall_score: overall_score,
      score_confidence: 1.0,
      disparity_score: 0.0,
      disparity_category: "perfect_harmony",
      unpredictability_score: 0.0,
      calculated_at: now,
      calculation_version: MovieScoreCacheWorker.current_version()
    })
  end

  defp insert_genre!(name) do
    Repo.insert!(%Genre{
      tmdb_id: System.unique_integer([:positive]),
      name: "#{name} #{System.unique_integer([:positive])}"
    })
  end

  defp insert_festival!(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    Repo.insert!(%FestivalOrganization{
      name: "#{name} #{System.unique_integer([:positive])}",
      slug: "#{slug}-#{System.unique_integer([:positive])}",
      abbreviation: "T#{System.unique_integer([:positive])}"
    })
  end

  defp insert_movie_list!(name) do
    unique = System.unique_integer([:positive])

    %MovieList{}
    |> MovieList.changeset(%{
      source_key: "slug_list_#{unique}",
      name: "#{name} #{unique}",
      slug: "slug-list-#{unique}",
      active: true,
      source_type: "custom",
      source_url: "https://example.test/list/#{unique}",
      category: "curated"
    })
    |> Repo.insert!()
  end

  defp insert_person!(name) do
    unique = System.unique_integer([:positive])

    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    %Person{}
    |> Person.changeset(%{
      tmdb_id: unique,
      name: "#{name} #{unique}",
      slug: "#{slug}-#{unique}"
    })
    |> Repo.insert!()
  end

  defp insert_company!(name) do
    unique = System.unique_integer([:positive])

    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    %ProductionCompany{}
    |> ProductionCompany.changeset(%{
      tmdb_id: unique,
      name: "#{name} #{unique}",
      slug: "#{slug}-#{unique}"
    })
    |> Repo.insert!()
  end

  defp add_genres!(%Movie{} = movie, genres) do
    rows =
      Enum.map(genres, fn genre ->
        %{movie_id: movie.id, genre_id: genre.id}
      end)

    Repo.insert_all("movie_genres", rows)
    movie
  end

  defp add_companies!(%Movie{} = movie, companies) do
    rows =
      Enum.map(companies, fn company ->
        %{movie_id: movie.id, production_company_id: company.id}
      end)

    Repo.insert_all("movie_production_companies", rows)
    movie
  end

  defp add_credit!(%Movie{} = movie, %Person{} = person, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          movie_id: movie.id,
          person_id: person.id,
          credit_type: "cast",
          cast_order: 0,
          credit_id: "credit-#{movie.id}-#{person.id}-#{System.unique_integer([:positive])}"
        },
        attrs
      )

    %Credit{}
    |> Credit.changeset(attrs)
    |> Repo.insert!()

    movie
  end

  defp movie_titles(movies), do: Enum.map(movies, & &1.title)
end
