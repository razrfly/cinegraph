defmodule CinegraphWeb.Schema.MovieQueryTest do
  use Cinegraph.DataCase, async: false

  alias CinegraphWeb.Schema
  alias Cinegraph.Repo
  alias Cinegraph.Movies.{Availability, Movie}
  alias Cinegraph.Workers.MovieAvailabilityRefreshWorker

  # Helper to run a GraphQL query against the schema directly
  defp run_query(query, opts \\ []) do
    context = Keyword.get(opts, :context, %{})
    variables = Keyword.get(opts, :variables, %{})
    Absinthe.run(query, Schema, context: context, variables: variables)
  end

  # Insert a minimal movie fixture directly
  defp insert_movie(attrs) do
    defaults = %{
      tmdb_id: :rand.uniform(999_999),
      title: "Test Movie",
      import_status: "full"
    }

    {:ok, movie} =
      %Movie{}
      |> Movie.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    movie
  end

  describe "movie query" do
    test "fetches a movie by tmdb_id" do
      movie = insert_movie(%{tmdb_id: 10_001, title: "Fight Club"})

      query = """
      query {
        movie(tmdbId: #{movie.tmdb_id}) {
          title
          tmdbId
        }
      }
      """

      assert {:ok, %{data: %{"movie" => result}}} = run_query(query)
      assert result["title"] == "Fight Club"
      assert result["tmdbId"] == movie.tmdb_id
    end

    test "returns nil for unknown tmdb_id" do
      query = """
      query {
        movie(tmdbId: 999999999) {
          title
        }
      }
      """

      assert {:ok, %{data: %{"movie" => nil}, errors: errors}} = run_query(query)
      assert Enum.any?(errors, fn e -> e.message == "Movie not found" end)
    end

    test "fetches a movie by slug" do
      movie = insert_movie(%{tmdb_id: 10_002, title: "The Godfather"})

      query = """
      query {
        movie(slug: "#{movie.slug}") {
          title
          slug
        }
      }
      """

      assert {:ok, %{data: %{"movie" => result}}} = run_query(query)
      assert result["title"] == "The Godfather"
      assert result["slug"] == movie.slug
    end

    test "ratings returns nil values when no external metrics exist" do
      movie = insert_movie(%{tmdb_id: 10_003})

      query = """
      query {
        movie(tmdbId: #{movie.tmdb_id}) {
          ratings {
            tmdb
            imdb
            rottenTomatoes
            metacritic
          }
        }
      }
      """

      assert {:ok, %{data: %{"movie" => result}}} = run_query(query)
      ratings = result["ratings"]
      assert ratings["tmdb"] == nil
      assert ratings["imdb"] == nil
      assert ratings["rottenTomatoes"] == nil
      assert ratings["metacritic"] == nil
    end
  end

  describe "movies batch query" do
    test "fetches multiple movies by tmdb_ids" do
      m1 = insert_movie(%{tmdb_id: 20_001, title: "Movie A"})
      m2 = insert_movie(%{tmdb_id: 20_002, title: "Movie B"})

      query = """
      query {
        movies(tmdbIds: [#{m1.tmdb_id}, #{m2.tmdb_id}]) {
          title
          tmdbId
        }
      }
      """

      assert {:ok, %{data: %{"movies" => results}}} = run_query(query)
      titles = Enum.map(results, & &1["title"])
      assert "Movie A" in titles
      assert "Movie B" in titles
    end

    test "returns empty list for unknown tmdb_ids" do
      query = """
      query {
        movies(tmdbIds: [999999990, 999999991]) {
          title
        }
      }
      """

      assert {:ok, %{data: %{"movies" => []}}} = run_query(query)
    end
  end

  describe "searchMovies query" do
    test "returns movies matching the query string" do
      insert_movie(%{tmdb_id: 30_001, title: "Inception"})
      insert_movie(%{tmdb_id: 30_002, title: "Interstellar"})

      query = """
      query {
        searchMovies(query: "Incep") {
          title
        }
      }
      """

      assert {:ok, %{data: %{"searchMovies" => results}}} = run_query(query)
      titles = Enum.map(results, & &1["title"])
      assert "Inception" in titles
      refute "Interstellar" in titles
    end

    test "respects the limit argument" do
      for i <- 1..5, do: insert_movie(%{tmdb_id: 40_000 + i, title: "The Movie #{i}"})

      query = """
      query {
        searchMovies(query: "The Movie", limit: 3) {
          title
        }
      }
      """

      assert {:ok, %{data: %{"searchMovies" => results}}} = run_query(query)
      assert length(results) <= 3
    end
  end

  describe "lens_scores field" do
    test "returns null when no score cache exists" do
      movie = insert_movie(%{tmdb_id: 60_001, title: "Uncached Movie"})

      query = """
      query {
        movie(tmdbId: #{movie.tmdb_id}) {
          lensScores {
            mob
            critics
            overall
            disparityCategory
          }
        }
      }
      """

      assert {:ok, %{data: %{"movie" => result}}} = run_query(query)
      assert result["lensScores"] == nil
    end

    test "returns lens scores when score cache exists" do
      movie = insert_movie(%{tmdb_id: 60_002, title: "Cached Movie"})

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        %Cinegraph.Movies.MovieScoreCache{}
        |> Cinegraph.Movies.MovieScoreCache.changeset(%{
          movie_id: movie.id,
          mob_score: 7.5,
          critics_score: 8.2,
          festival_recognition_score: 6.0,
          time_machine_score: 5.5,
          auteurs_score: 7.0,
          box_office_score: 4.0,
          overall_score: 6.8,
          score_confidence: 0.85,
          disparity_score: 0.7,
          disparity_category: "critics_darling",
          unpredictability_score: 2.1,
          calculated_at: now,
          calculation_version: "1.0"
        })
        |> Repo.insert()

      query = """
      query {
        movie(tmdbId: #{movie.tmdb_id}) {
          lensScores {
            mob
            critics
            overall
            confidence
            displayScore
            sortScore
            scoreabilityState
            scoreConfidenceLabel
            presentLensCount
            missingLensCount
            presentLensLabels
            missingLensLabels
            scoreHiddenReason
            disparityCategory
          }
        }
      }
      """

      assert {:ok, %{data: %{"movie" => result}}} = run_query(query)
      scores = result["lensScores"]
      assert scores["mob"] == 7.5
      assert scores["critics"] == 8.2
      assert scores["overall"] == 6.8
      assert scores["confidence"] == 0.85
      assert scores["displayScore"] == 6.8
      assert_in_delta scores["sortScore"], 6.8, 0.001
      assert scores["scoreabilityState"] == "scoreable"
      assert scores["scoreConfidenceLabel"] == "high"
      assert scores["presentLensCount"] == 6
      assert scores["missingLensCount"] == 0

      assert scores["presentLensLabels"] == [
               "mob",
               "critics",
               "festival_recognition",
               "time_machine",
               "auteurs",
               "box_office"
             ]

      assert scores["missingLensLabels"] == []
      assert scores["scoreHiddenReason"] == "none"
      assert scores["disparityCategory"] == "critics_darling"
    end

    test "lens scores hide public display score when evidence is insufficient" do
      movie = insert_movie(%{tmdb_id: 60_003, title: "Sparse Cached Movie"})
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        %Cinegraph.Movies.MovieScoreCache{}
        |> Cinegraph.Movies.MovieScoreCache.changeset(%{
          movie_id: movie.id,
          mob_score: 7.5,
          critics_score: 0.0,
          festival_recognition_score: 0.0,
          time_machine_score: 0.0,
          auteurs_score: 0.0,
          box_office_score: 0.0,
          overall_score: 1.2,
          score_confidence: 0.25,
          disparity_score: 0.0,
          disparity_category: "perfect_harmony",
          unpredictability_score: 0.0,
          calculated_at: now,
          calculation_version: "1.0"
        })
        |> Repo.insert()

      query = """
      query {
        movie(tmdbId: #{movie.tmdb_id}) {
          lensScores {
            overall
            displayScore
            sortScore
            scoreabilityState
            scoreConfidenceLabel
            presentLensCount
            scoreHiddenReason
          }
        }
      }
      """

      assert {:ok, %{data: %{"movie" => result}}} = run_query(query)
      scores = result["lensScores"]
      assert scores["overall"] == 1.2
      assert scores["displayScore"] == nil
      assert scores["sortScore"] == nil
      assert scores["scoreabilityState"] == "insufficient_evidence"
      assert scores["scoreConfidenceLabel"] == "insufficient"
      assert scores["presentLensCount"] == 1
      assert scores["scoreHiddenReason"] == "not_enough_evidence"
    end
  end

  describe "availability field" do
    test "returns default-region availability grouped by monetization type" do
      movie = insert_movie(%{tmdb_id: 70_001, title: "Available Movie"})

      assert {:ok, _} =
               Availability.store_tmdb_watch_providers(movie, %{
                 "results" => %{
                   "US" => %{
                     "link" => "https://example.test/us-watch",
                     "flatrate" => [
                       provider(9, "Prime Video", 9, "/prime.jpg"),
                       provider(8, "Netflix", 1, "/netflix.jpg")
                     ],
                     "rent" => [provider(10, "Amazon Video", 4, "/amazon.jpg")]
                   },
                   "GB" => %{
                     "link" => "https://example.test/gb-watch",
                     "buy" => [provider(2, "Apple TV", 2, "/apple.jpg")]
                   }
                 }
               })

      query = """
      query {
        movie(tmdbId: #{movie.tmdb_id}) {
          availability {
            region
            regionLabel
            status
            tmdbLink
            fetchedAt
            staleAfter
            isStale
            refreshQueued
            availableRegions { region label }
            groups {
              monetizationType
              label
              providers {
                monetizationType
                displayPriority
                tmdbLink
                fetchedAt
                staleAfter
                provider {
                  source
                  sourceProviderId
                  tmdbProviderId
                  name
                  logoPath
                  logoUrl
                  displayPriorities
                }
              }
            }
          }
        }
      }
      """

      assert {:ok, %{data: %{"movie" => %{"availability" => availability}}}} = run_query(query)

      assert availability["region"] == "US"
      assert availability["regionLabel"] == "🇺🇸 United States"
      assert availability["status"] == "success"
      assert availability["tmdbLink"] == "https://example.test/us-watch"
      assert availability["fetchedAt"] =~ "T"
      assert availability["staleAfter"] =~ "T"
      refute availability["isStale"]
      refute availability["refreshQueued"]

      assert availability["availableRegions"] == [
               %{"region" => "GB", "label" => "🇬🇧 United Kingdom"},
               %{"region" => "US", "label" => "🇺🇸 United States"}
             ]

      streaming = Enum.find(availability["groups"], &(&1["monetizationType"] == "flatrate"))
      assert streaming["label"] == "Streaming"

      assert Enum.map(streaming["providers"], &get_in(&1, ["provider", "name"])) == [
               "Netflix",
               "Prime Video"
             ]

      [netflix | _] = streaming["providers"]
      assert netflix["monetizationType"] == "flatrate"
      assert netflix["displayPriority"] == 1
      assert netflix["tmdbLink"] == "https://example.test/us-watch"
      assert netflix["provider"]["source"] == "tmdb"
      assert netflix["provider"]["sourceProviderId"] == "8"
      assert netflix["provider"]["tmdbProviderId"] == 8
      assert netflix["provider"]["logoPath"] == "/netflix.jpg"
      assert netflix["provider"]["logoUrl"] == "https://image.tmdb.org/t/p/w92/netflix.jpg"
      assert netflix["provider"]["displayPriorities"] == %{}

      rent = Enum.find(availability["groups"], &(&1["monetizationType"] == "rent"))
      assert rent["label"] == "Rent"
      assert Enum.map(rent["providers"], &get_in(&1, ["provider", "name"])) == ["Amazon Video"]
    end

    test "returns explicit region availability without leaking default-region providers" do
      movie = insert_movie(%{tmdb_id: 70_002, title: "Regional Movie"})

      assert {:ok, _} =
               Availability.store_tmdb_watch_providers(movie, %{
                 "results" => %{
                   "US" => %{"flatrate" => [provider(8, "Netflix", 1, "/netflix.jpg")]},
                   "GB" => %{"rent" => [provider(2, "Apple TV", 2, "/apple.jpg")]}
                 }
               })

      query = """
      query {
        movie(tmdbId: #{movie.tmdb_id}) {
          availability(region: "gb") {
            region
            regionLabel
            groups {
              monetizationType
              providers { provider { name } }
            }
          }
        }
      }
      """

      assert {:ok, %{data: %{"movie" => %{"availability" => availability}}}} = run_query(query)
      assert availability["region"] == "GB"
      assert availability["regionLabel"] == "🇬🇧 United Kingdom"

      rent = Enum.find(availability["groups"], &(&1["monetizationType"] == "rent"))
      streaming = Enum.find(availability["groups"], &(&1["monetizationType"] == "flatrate"))

      assert Enum.map(rent["providers"], &get_in(&1, ["provider", "name"])) == ["Apple TV"]
      assert streaming["providers"] == []
    end

    test "returns no_results, error, never_fetched, stale, and queued states" do
      movie = insert_movie(%{tmdb_id: 70_003, title: "State Movie"})

      assert {:ok, _} =
               Availability.store_tmdb_watch_providers(movie, %{
                 "results" => %{
                   "US" => %{"link" => "https://example.test/no-results"}
                 }
               })

      assert {:ok, _} = Availability.record_availability_error(movie, ["GB"], :tmdb_down)

      stale_movie = insert_movie(%{tmdb_id: 70_004, title: "Stale Movie"})

      assert {:ok, _} =
               Availability.store_tmdb_watch_providers(
                 stale_movie,
                 %{
                   "results" => %{
                     "US" => %{"rent" => [provider(3, "Fandango At Home", 1, "/fandango.jpg")]}
                   }
                 },
                 fetched_at: ~U[2026-01-01 00:00:00Z],
                 stale_after: ~U[2026-01-31 00:00:00Z]
               )

      Repo.delete_all(Oban.Job)

      %{"movie_id" => movie.id, "force" => true}
      |> MovieAvailabilityRefreshWorker.new()
      |> Oban.insert!()

      query = """
      query {
        noResults: movie(tmdbId: #{movie.tmdb_id}) {
          availability(region: "US") { region status isStale refreshQueued tmdbLink groups { providers { provider { name } } } }
        }
        errorState: movie(tmdbId: #{movie.tmdb_id}) {
          availability(region: "GB") { region status refreshQueued }
        }
        neverFetched: movie(tmdbId: #{movie.tmdb_id}) {
          availability(region: "CA") { region status refreshQueued }
        }
        staleState: movie(tmdbId: #{stale_movie.tmdb_id}) {
          availability(region: "US") { region status isStale }
        }
      }
      """

      assert {:ok, %{data: data}} = run_query(query)

      no_results = get_in(data, ["noResults", "availability"])
      assert no_results["region"] == "US"
      assert no_results["status"] == "no_results"
      assert no_results["tmdbLink"] == "https://example.test/no-results"
      assert no_results["refreshQueued"]
      refute no_results["isStale"]
      assert Enum.all?(no_results["groups"], &(&1["providers"] == []))

      assert get_in(data, ["errorState", "availability", "status"]) == "error"
      assert get_in(data, ["errorState", "availability", "refreshQueued"])

      assert get_in(data, ["neverFetched", "availability", "region"]) == "CA"
      assert get_in(data, ["neverFetched", "availability", "status"]) == "never_fetched"
      assert get_in(data, ["neverFetched", "availability", "refreshQueued"])

      assert get_in(data, ["staleState", "availability", "status"]) == "success"
      assert get_in(data, ["staleState", "availability", "isStale"])
    end
  end

  describe "authentication" do
    setup do
      Application.put_env(:cinegraph, :api_key, "secret-key")
      on_exit(fn -> Application.delete_env(:cinegraph, :api_key) end)
      :ok
    end

    test "rejects requests without a valid token" do
      query = """
      query {
        movie(tmdbId: 550) {
          title
        }
      }
      """

      assert {:ok, %{errors: errors}} = run_query(query, context: %{})
      assert Enum.any?(errors, fn e -> e.message == "unauthorized" end)
    end

    test "allows requests with the correct token" do
      movie = insert_movie(%{tmdb_id: 50_001, title: "Authenticated Movie"})

      query = """
      query {
        movie(tmdbId: #{movie.tmdb_id}) {
          title
        }
      }
      """

      assert {:ok, %{data: %{"movie" => result}}} =
               run_query(query, context: %{auth_token: "secret-key"})

      assert result["title"] == "Authenticated Movie"
    end
  end

  defp provider(id, name, priority, logo_path) do
    %{
      "provider_id" => id,
      "provider_name" => name,
      "display_priority" => priority,
      "logo_path" => logo_path
    }
  end
end
