defmodule Cinegraph.Scoring.PriorCollabDensityTest do
  @moduledoc """
  Data-backed leakage/aggregation contract for the `prior_collab_density` derived feature (#1044).

  Unlike `DerivedFeaturesTest` (which exercises the no-signal path against an empty matview), this
  populates `collaborations`/`collaboration_details`/`movie_credits`, `REFRESH`es
  `person_collaboration_trends` inside the sandbox transaction, and asserts the real math:
  `SUM(new_collaborators)` over years **strictly before** the film's release year, log-normalized at
  threshold 50. `async: false` because a non-concurrent `REFRESH MATERIALIZED VIEW` takes an
  ACCESS EXCLUSIVE lock on the shared matview relation.
  """
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Collaborations.{Collaboration, CollaborationDetail}
  alias Cinegraph.Movies.{Credit, Movie, Person}
  alias Cinegraph.Repo
  alias Cinegraph.Scoring.DerivedFeatures

  @sk "1001_movies"
  # Pulled from the single source of truth so tuning the cap doesn't require editing this contract
  # test (which pins the leakage/aggregation math, not the saturation constant).
  @cap DerivedFeatures.prior_collab_cap()

  defp uniq, do: System.unique_integer([:positive])

  defp person!(name) do
    %Person{} |> Person.changeset(%{tmdb_id: uniq(), name: "#{name} #{uniq()}"}) |> Repo.insert!()
  end

  defp movie!(year) do
    %Movie{}
    |> Movie.changeset(%{
      tmdb_id: uniq(),
      title: "Film #{uniq()}",
      release_date: Date.new!(year, 6, 1)
    })
    |> Repo.insert!()
  end

  defp direct!(movie, person) do
    %Credit{}
    |> Credit.changeset(%{
      movie_id: movie.id,
      person_id: person.id,
      credit_type: "crew",
      department: "Directing",
      job: "Director",
      credit_id: "credit-#{uniq()}"
    })
    |> Repo.insert!()
  end

  # Records that `person` collaborated with `collaborator` on a film released in `year`.
  defp collaborated!(person, collaborator, year) do
    {a, b} =
      if person.id < collaborator.id, do: {person, collaborator}, else: {collaborator, person}

    collab =
      %Collaboration{}
      |> Collaboration.changeset(%{
        person_a_id: a.id,
        person_b_id: b.id,
        collaboration_count: 1,
        years_active: [year]
      })
      |> Repo.insert!()

    %CollaborationDetail{}
    |> CollaborationDetail.changeset(%{
      collaboration_id: collab.id,
      movie_id: movie!(year).id,
      collaboration_type: "director-director",
      year: year
    })
    |> Repo.insert!()
  end

  defp refresh_trends! do
    Repo.query!("REFRESH MATERIALIZED VIEW person_collaboration_trends")
  end

  defp density(movie) do
    DerivedFeatures.load([movie], ["prior_collab_density"], @sk)[movie.id]["prior_collab_density"]
  end

  defp log_norm(x), do: :math.log(1.0 + x) / :math.log(1.0 + @cap)

  test "sums distinct prior-year collaborators, excluding the release year and the future" do
    director = person!("Director")

    # Four distinct collaborators, each first seen in a different year ⇒ new_collaborators = 1/year.
    for {collab_year, name} <- [{2010, "C1"}, {2012, "C2"}, {2015, "C3"}, {2018, "C4"}] do
      collaborated!(director, person!(name), collab_year)
    end

    refresh_trends!()

    # Film released 2015: only 2010 + 2012 are strictly prior ⇒ Σ new_collaborators = 2.
    # 2015 (== release year, the leakage guard) and 2018 (future) must be excluded.
    film_2015 = movie!(2015)
    direct!(film_2015, director)
    assert_in_delta density(film_2015), log_norm(2), 1.0e-9

    # The cutoff moves with the release year: a 2011 film sees only 2010 ⇒ Σ = 1.
    film_2011 = movie!(2011)
    direct!(film_2011, director)
    assert_in_delta density(film_2011), log_norm(1), 1.0e-9

    # A debut-era film (released before any prior collaboration) gets no signal ⇒ 0.0.
    film_2009 = movie!(2009)
    direct!(film_2009, director)
    assert density(film_2009) == 0.0
  end

  test "a key person credited under multiple roles is not double-counted" do
    director = person!("Multi")
    collaborated!(director, person!("X"), 2010)
    collaborated!(director, person!("Y"), 2011)
    refresh_trends!()

    film = movie!(2015)
    # Same person credited as both Director (crew) and a top-billed cast member.
    direct!(film, director)

    %Credit{}
    |> Credit.changeset(%{
      movie_id: film.id,
      person_id: director.id,
      credit_type: "cast",
      character: "Self",
      cast_order: 0,
      credit_id: "credit-#{uniq()}"
    })
    |> Repo.insert!()

    # 2 distinct prior collaborators counted once, not 4 (DISTINCT in the key_people CTE).
    assert_in_delta density(film), log_norm(2), 1.0e-9
  end
end
