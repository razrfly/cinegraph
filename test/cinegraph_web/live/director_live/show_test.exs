defmodule CinegraphWeb.DirectorLive.ShowTest do
  # async: false so the sandbox runs in shared mode — the LiveView's mount async
  # task (a separate process) can then reach this test's DB connection.
  use CinegraphWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinegraph.Movies.{Credit, ExternalMetric, Movie, Person}
  alias Cinegraph.Repo

  setup do
    # get_collaboration_network/1 reads via Cinegraph.Repo.replica(), which in test
    # resolves to a *separate* Repo.Replica sandbox pool that can't see this test's
    # writes. Force replica/0 back to the primary Repo for the duration of this test.
    prev = System.get_env("USE_REPLICA")
    System.put_env("USE_REPLICA", "false")

    on_exit(fn ->
      case prev do
        nil -> System.delete_env("USE_REPLICA")
        val -> System.put_env("USE_REPLICA", val)
      end
    end)

    :ok
  end

  describe "/directors/:id collaboration network" do
    # Regression test for #1056: get_collaboration_network/1 selected AVG(m.vote_average)
    # while joining the bare `movies` table, but vote_average lives only on the
    # movies_with_metrics view. The query errored in Postgres and was swallowed to [],
    # leaving the section silently empty. This asserts the section renders with data.
    test "renders crew collaborators with avg rating", %{conn: conn} do
      director = insert_person!("Reg Director", 990_101, known_for_department: "Directing")
      writer = insert_person!("Reg Writer", 990_102)

      # Two shared movies satisfy the query's HAVING COUNT(DISTINCT movie_id) >= 2.
      for {title, date} <- [{"Reg Film One", ~D[2001-01-01]}, {"Reg Film Two", ~D[2002-01-01]}] do
        movie = insert_movie!(title, date)
        insert_crew_credit!(movie, director, "Director", "Directing")
        insert_crew_credit!(movie, writer, "Writer", "Writing")
        insert_tmdb_rating!(movie, 7.5)
      end

      {:ok, view, _html} = live(conn, ~p"/directors/#{director.id}")
      html = render_async(view)

      # Section header only renders when the network query returned rows.
      assert html =~ "Key Crew Collaborators"
      # The writer is not cast, so its appearance proves the collaboration query worked.
      assert html =~ "Reg Writer"
      # avg_rating resolved through movies_with_metrics → external_metrics.
      assert html =~ "★"
    end
  end

  defp insert_person!(name, tmdb_id, attrs \\ []) do
    %Person{}
    |> Person.changeset(Enum.into(attrs, %{name: name, tmdb_id: tmdb_id}))
    |> Repo.insert!()
  end

  defp insert_movie!(title, release_date) do
    %Movie{}
    |> Movie.changeset(%{
      title: title,
      tmdb_id: System.unique_integer([:positive]),
      release_date: release_date,
      import_status: "full"
    })
    |> Repo.insert!()
  end

  defp insert_crew_credit!(movie, person, job, department) do
    %Credit{}
    |> Credit.changeset(%{
      movie_id: movie.id,
      person_id: person.id,
      credit_type: "crew",
      department: department,
      job: job,
      credit_id: "crew-#{movie.id}-#{person.id}-#{job}"
    })
    |> Repo.insert!()
  end

  defp insert_tmdb_rating!(movie, value) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    now_naive = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert_all(ExternalMetric, [
      %{
        movie_id: movie.id,
        source: "tmdb",
        metric_type: "rating_average",
        value: value,
        fetched_at: now,
        inserted_at: now_naive,
        updated_at: now_naive
      }
    ])
  end
end
