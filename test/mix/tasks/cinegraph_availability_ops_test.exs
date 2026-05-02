defmodule Mix.Tasks.CinegraphAvailabilityOpsTest do
  use Cinegraph.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureIO

  alias Cinegraph.Movies.Movie
  alias Cinegraph.Repo

  setup do
    Mix.Task.reenable("cinegraph.drift")
    Mix.Task.reenable("cinegraph.audit.availability")
    Mix.Task.reenable("cinegraph.refresh.availability")
    Mix.Task.reenable("app.start")
    :ok
  end

  test "local drift task supports availability domain as JSON" do
    output =
      capture_io(fn ->
        Mix.Tasks.Cinegraph.Drift.run(["availability", "--json", "--limit", "1"])
      end)

    assert output =~ "availability_missing"
    assert output =~ "availability_stale"
    assert output =~ "availability_fetch_errors"
    assert output =~ "availability_provider_catalog_stale"
  end

  test "prod drift task supports availability expression" do
    expr =
      Mix.Tasks.Cinegraph.Prod.Drift.build_expression(
        "Cinegraph.Health.Drift.Availability",
        limit: 3
      )

    assert expr ==
             "IO.puts(Jason.encode!(Cinegraph.Health.Drift.Availability.all([limit: 3])))"
  end

  test "prod availability audit builds safe ProdRpc expression" do
    expr =
      Mix.Tasks.Cinegraph.Prod.Audit.Availability.build_expression(
        json: true,
        limit: 3,
        region: "PL",
        "stale-days": 14
      )

    assert expr =~ "Cinegraph.Health.AvailabilityAudit.audit"
    assert expr =~ "limit: 3"
    assert expr =~ ~s|region: "PL"|
    assert expr =~ "stale_days: 14"
  end

  test "prod availability backfill builds dry-run resumable expression" do
    expr =
      Mix.Tasks.Cinegraph.Prod.Movies.BackfillAvailability.build_expression(
        json: true,
        dry_run: true,
        limit: 100,
        after_id: 500,
        batch_size: 50,
        regions: "US,GB"
      )

    assert expr =~
             ~s|case Cinegraph.Movies.AvailabilityBackfill.run([limit: 100, after_id: 500, batch_size: 50, regions: "US,GB", dry_run: true]) do|

    assert expr =~ "{:ok, stats} -> IO.puts(Jason.encode!(stats))"
    assert expr =~ "{:error, reason} -> IO.puts(Jason.encode!(%{error: inspect(reason)}))"
  end

  test "prod availability backfill defaults to all configured regions" do
    expr =
      Mix.Tasks.Cinegraph.Prod.Movies.BackfillAvailability.build_expression(
        json: true,
        dry_run: true
      )

    assert expr =~
             ~s|case Cinegraph.Movies.AvailabilityBackfill.run([regions: Cinegraph.Movies.Availability.configured_regions(), dry_run: true]) do|

    assert expr =~ "{:ok, stats} -> IO.puts(Jason.encode!(stats))"
    assert expr =~ "{:error, reason} -> IO.puts(Jason.encode!(%{error: inspect(reason)}))"
  end

  test "refresh availability task validates ids and enqueues forced jobs" do
    Repo.delete_all(Oban.Job)
    movie = insert_movie!()

    output =
      capture_io(fn ->
        Mix.Tasks.Cinegraph.Refresh.Availability.run([Integer.to_string(movie.id)])
      end)

    assert output =~ "Enqueued 1 MovieAvailabilityRefreshWorker job"

    [job] =
      Repo.all(
        from(j in Oban.Job,
          where: j.worker == "Cinegraph.Workers.MovieAvailabilityRefreshWorker"
        )
      )

    assert job.worker == "Cinegraph.Workers.MovieAvailabilityRefreshWorker"
    assert job.args["movie_id"] == movie.id
    assert job.args["force"] == true
    refute Map.has_key?(job.args, "regions")
  end

  defp insert_movie! do
    %Movie{}
    |> Movie.changeset(%{
      tmdb_id: System.unique_integer([:positive]),
      title: "Refresh Availability Movie",
      original_title: "Refresh Availability Movie",
      import_status: "full"
    })
    |> Repo.insert!()
  end
end
