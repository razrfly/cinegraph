defmodule Cinegraph.VideoClerkTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Movies.{Credit, Genre, Keyword, Movie, MovieScoreCache, Person}
  alias Cinegraph.Repo
  alias Cinegraph.VideoClerk
  alias Cinegraph.Workers.MovieScoreCacheWorker

  test "recommend/2 returns a primary recommendation with explanations and alternates" do
    drama = insert_genre!("Drama")
    offbeat = insert_keyword!("offbeat")
    clerk = insert_person!("Clerk Director")

    seed =
      insert_movie!("Seed Oddball", canonical_sources: %{})
      |> add_genres!([drama])
      |> add_keywords!([offbeat])
      |> add_credit!(clerk, %{credit_type: "crew", department: "Directing", job: "Director"})

    primary =
      insert_movie!("Cult Canon Pick",
        canonical_sources: %{
          "cult_movies_400" => %{"included" => true},
          "1001_movies" => %{"included" => true}
        }
      )
      |> add_genres!([drama])
      |> add_keywords!([offbeat])
      |> add_credit!(clerk, %{credit_type: "crew", department: "Directing", job: "Director"})
      |> add_score_cache!()

    alternate =
      insert_movie!("Cult Alternate",
        canonical_sources: %{"cult_movies_400" => %{"included" => true}}
      )
      |> add_genres!([drama])

    result = VideoClerk.recommend([seed.id], limit: 3)

    assert result.primary.id == primary.id
    assert Enum.map(result.alternates, & &1.id) == [alternate.id]
    assert "Cult afterlife" in result.primary.route_labels
    assert "Human graph" in result.primary.route_labels
    assert result.primary.reason =~ "Cult Canon Pick is the clerk's move"
  end

  test "recommend/2 excludes seed movies and handles empty inputs gracefully" do
    movie =
      insert_movie!("Lonely Seed",
        canonical_sources: %{"cult_movies_400" => %{"included" => true}}
      )

    assert %{primary: nil, alternates: []} = VideoClerk.recommend([])
    assert %{primary: nil, alternates: []} = VideoClerk.recommend([movie.id])
  end

  test "recommend/2 works with up to three seed movies" do
    comedy = insert_genre!("Comedy")

    seed_a = insert_movie!("Seed A") |> add_genres!([comedy])
    seed_b = insert_movie!("Seed B") |> add_genres!([comedy])
    seed_c = insert_movie!("Seed C") |> add_genres!([comedy])

    pick =
      insert_movie!("Three Seed Pick",
        canonical_sources: %{"cult_movies_400" => %{"included" => true}}
      )
      |> add_genres!([comedy])

    result = VideoClerk.recommend([seed_a.id, seed_b.id, seed_c.id], limit: 1)

    assert result.primary.id == pick.id
    assert length(result.seed_movies) == 3
  end

  defp insert_movie!(title, attrs \\ []) do
    defaults = %{
      tmdb_id: System.unique_integer([:positive]),
      title: title,
      original_title: title,
      release_date: ~D[1984-01-01],
      import_status: "full",
      canonical_sources: %{}
    }

    %Movie{}
    |> Movie.changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end

  defp insert_genre!(name) do
    %Genre{}
    |> Genre.changeset(%{tmdb_id: System.unique_integer([:positive]), name: name})
    |> Repo.insert!()
  end

  defp insert_keyword!(name) do
    %Keyword{}
    |> Keyword.changeset(%{tmdb_id: System.unique_integer([:positive]), name: name})
    |> Repo.insert!()
  end

  defp insert_person!(name) do
    %Person{}
    |> Person.changeset(%{tmdb_id: System.unique_integer([:positive]), name: name})
    |> Repo.insert!()
  end

  defp add_genres!(movie, genres) do
    Repo.insert_all(
      "movie_genres",
      Enum.map(genres, &%{movie_id: movie.id, genre_id: &1.id})
    )

    movie
  end

  defp add_keywords!(movie, keywords) do
    Repo.insert_all(
      "movie_keywords",
      Enum.map(keywords, &%{movie_id: movie.id, keyword_id: &1.id})
    )

    movie
  end

  defp add_credit!(movie, person, attrs) do
    defaults = %{
      movie_id: movie.id,
      person_id: person.id,
      credit_type: "cast",
      credit_id: "credit-#{System.unique_integer([:positive])}"
    }

    %Credit{}
    |> Credit.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()

    movie
  end

  defp add_score_cache!(movie) do
    %MovieScoreCache{}
    |> MovieScoreCache.changeset(%{
      movie_id: movie.id,
      mob_score: 4.0,
      critics_score: 6.0,
      festival_recognition_score: 2.0,
      time_machine_score: 8.0,
      auteurs_score: 7.0,
      box_office_score: 1.0,
      overall_score: 7.0,
      score_confidence: 0.8,
      unpredictability_score: 6.0,
      calculated_at: DateTime.utc_now() |> DateTime.truncate(:second),
      calculation_version: MovieScoreCacheWorker.current_version()
    })
    |> Repo.insert!()

    movie
  end
end
