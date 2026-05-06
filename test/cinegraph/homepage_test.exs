defmodule Cinegraph.HomepageTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Collaborations.{Collaboration, CollaborationDetail}
  alias Cinegraph.Events.{FestivalDate, FestivalEvent}
  alias Cinegraph.Homepage
  alias Cinegraph.Movies.{Movie, MovieList, MovieScoreCache, Person}
  alias Cinegraph.Repo

  setup do
    Cachex.clear(:movies_cache)
    Cachex.clear(:health_cache)
    :ok
  end

  test "snapshot is deterministic for a UTC date and degrades on sparse data" do
    date = ~D[2026-05-05]

    first = Homepage.snapshot(date)
    second = Homepage.snapshot(date)

    assert first.hero.title == second.hero.title
    assert first.spotlight.title == second.spotlight.title
    assert is_integer(first.corpus_tagline.count)
    assert is_binary(first.corpus_tagline.copy)
    assert is_list(first.activity)
  end

  test "snapshot aggregates homepage modules from existing data" do
    date = ~D[2026-05-05]
    list_a = insert_list!("list_a", "List A", "list-a", 1)
    list_b = insert_list!("list_b", "List B", "list-b", 2)

    canon =
      insert_movie!("Canon One", ~D[1975-05-05], %{
        list_a.source_key => %{"included" => true},
        list_b.source_key => %{"included" => true}
      })

    theater = insert_movie!("New Release", ~D[2026-05-10], %{list_a.source_key => %{}})
    # The home "in or near theaters" section requires >= 4 recent releases
    # before it renders; seed three additional sparse rows so the test data
    # crosses that bar.
    for n <- 1..3 do
      insert_movie!("Filler Release #{n}", Date.add(~D[2026-05-10], -n), %{})
    end

    insert_score_cache!(canon, 9.2, [8.0, 9.5, 7.0, 9.9, 8.2, 6.0], "polarizer")
    insert_score_cache!(theater, 7.4, [7.4, 7.0, 3.0, 4.0, 5.0, 6.0], "peoples_champion")

    person_a = insert_person!("Actor One")
    person_b = insert_person!("Actor Two")
    collaboration = insert_collaboration!(person_a, person_b)
    insert_detail!(collaboration, canon)

    event = insert_event!("cannes", "Cannes Film Festival")
    insert_date!(event, 2026, ~D[2026-05-12], ~D[2026-05-23], "upcoming")
    insert_date!(event, 2025, ~D[2025-05-12], ~D[2025-05-23], "completed")

    snapshot = Homepage.snapshot(date)

    assert snapshot.corpus_tagline.count >= 2
    assert Enum.any?(snapshot.lens.movies, &(&1.title in ["Canon One", "New Release"]))
    assert Enum.any?(snapshot.theaters, &(&1.title == "New Release"))
    assert snapshot.six_degrees.person_a.name in ["Actor One", "Actor Two"]
    assert snapshot.festival_pulse.next.title =~ "Cannes"
    assert Enum.any?(snapshot.popular_lists, &(&1.title in ["List A", "List B"]))
  end

  defp insert_movie!(title, release_date, canonical_sources) do
    attrs = %{
      tmdb_id: System.unique_integer([:positive]),
      title: title,
      release_date: release_date,
      poster_path: "/#{String.replace(title, " ", "_")}.jpg",
      canonical_sources: canonical_sources,
      adult: false
    }

    %Movie{} |> Movie.changeset(attrs) |> Repo.insert!()
  end

  defp insert_person!(name) do
    %Person{}
    |> Person.changeset(%{
      tmdb_id: System.unique_integer([:positive]),
      name: name,
      known_for_department: "Acting",
      adult: false,
      popularity: 10.0
    })
    |> Repo.insert!()
  end

  defp insert_list!(source_key, name, slug, order) do
    Repo.insert!(%MovieList{
      source_key: source_key,
      name: name,
      short_name: name,
      slug: slug,
      source_type: "imdb",
      source_url: "https://www.imdb.com/list/ls#{System.unique_integer([:positive])}/",
      source_id: "ls#{System.unique_integer([:positive])}",
      category: "curated",
      active: true,
      display_order: order,
      description: "#{name} description"
    })
  end

  defp insert_score_cache!(movie, overall, [mob, critics, festival, time, auteurs, box], category) do
    Repo.insert!(%MovieScoreCache{
      movie_id: movie.id,
      mob_score: mob,
      critics_score: critics,
      festival_recognition_score: festival,
      time_machine_score: time,
      auteurs_score: auteurs,
      box_office_score: box,
      overall_score: overall,
      score_confidence: 1.0,
      disparity_score: abs(mob - critics),
      disparity_category: category,
      unpredictability_score: 0.0,
      calculated_at: DateTime.utc_now() |> DateTime.truncate(:second),
      calculation_version: "test"
    })
  end

  defp insert_collaboration!(person_a, person_b) do
    {a, b} = if person_a.id < person_b.id, do: {person_a, person_b}, else: {person_b, person_a}

    Repo.insert!(%Collaboration{
      person_a_id: a.id,
      person_b_id: b.id,
      collaboration_count: 1,
      years_active: [1975]
    })
  end

  defp insert_detail!(collaboration, movie) do
    Repo.insert!(%CollaborationDetail{
      collaboration_id: collaboration.id,
      movie_id: movie.id,
      collaboration_type: "actor-actor",
      year: movie.release_date.year
    })
  end

  defp insert_event!(source_key, name) do
    Repo.insert!(%FestivalEvent{
      source_key: source_key,
      name: name,
      primary_source: "official",
      active: true,
      country: "France",
      ceremony_vs_festival: "festival",
      import_priority: 100
    })
  end

  defp insert_date!(event, year, start_date, end_date, status) do
    Repo.insert!(%FestivalDate{
      festival_event_id: event.id,
      year: year,
      start_date: start_date,
      end_date: end_date,
      status: status
    })
  end
end
