defmodule Cinegraph.Maintenance.SyncFestivalsTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Events.FestivalEvent
  alias Cinegraph.Festivals.{FestivalCeremony, FestivalOrganization}
  alias Cinegraph.Maintenance.SyncFestivals
  alias Cinegraph.Repo

  describe "run/1 (#745 Phase 2)" do
    test "no active events → counts are zero" do
      assert {:ok,
              %{
                events: 0,
                discoveries_enqueued: 0,
                discoveries_already_queued: 0,
                imports_enqueued: 0,
                imports_already_queued: 0,
                failed: 0,
                dry_run: false
              }} = SyncFestivals.run([])
    end

    test "active event with no discovered_years → enqueues discovery only" do
      _event = insert_active_event!(source_key: "testfest", abbreviation: "TF1")

      assert {:ok, %{events: 1, discoveries_enqueued: 1, imports_enqueued: 0}} =
               SyncFestivals.run([])

      assert year_discovery_job_count() == 1
      assert unified_festival_job_count() == 0
    end

    test "active event with discovered_years and no existing ceremonies → enqueues imports" do
      _event =
        insert_active_event!(
          source_key: "testfest2",
          abbreviation: "TF2",
          discovered_years: [2023, 2024]
        )

      assert {:ok, %{events: 1, discoveries_enqueued: 1, imports_enqueued: 2}} =
               SyncFestivals.run([])

      assert unified_festival_job_count() == 2
    end

    test "active event with discovered_years partially imported → only imports the diff" do
      event =
        insert_active_event!(
          source_key: "testfest3",
          abbreviation: "TF3",
          discovered_years: [2022, 2023, 2024]
        )

      org = insert_org!(abbreviation: event.abbreviation)
      insert_ceremony!(org, year: 2022)
      insert_ceremony!(org, year: 2024)

      assert {:ok, %{events: 1, imports_enqueued: 1}} = SyncFestivals.run([])
      # Only 2023 should have been enqueued
      assert unified_festival_job_count() == 1
    end

    test "dry-run skips both passes" do
      _event =
        insert_active_event!(
          source_key: "testfest4",
          abbreviation: "TF4",
          discovered_years: [2024]
        )

      assert {:ok,
              %{
                discoveries_enqueued: 0,
                imports_enqueued: 1,
                imports_already_queued: 0,
                dry_run: true
              }} = SyncFestivals.run(dry_run: true)

      assert year_discovery_job_count() == 0
      assert unified_festival_job_count() == 0
    end

    test "non-active events are ignored" do
      _inactive_event =
        insert_event!(
          source_key: "inactive_fest",
          abbreviation: "IFA",
          active: false,
          discovered_years: [2024]
        )

      assert {:ok, %{events: 0, discoveries_enqueued: 0, imports_enqueued: 0}} =
               SyncFestivals.run([])
    end
  end

  # ===== fixtures =====

  defp insert_active_event!(opts), do: insert_event!(Keyword.put(opts, :active, true))

  defp insert_event!(opts) do
    attrs = %{
      source_key: Keyword.fetch!(opts, :source_key),
      name: "Test Festival #{System.unique_integer([:positive])}",
      primary_source: "custom",
      active: Keyword.get(opts, :active, true),
      abbreviation: Keyword.get(opts, :abbreviation),
      discovered_years: Keyword.get(opts, :discovered_years, [])
    }

    %FestivalEvent{}
    |> FestivalEvent.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_org!(opts) do
    %FestivalOrganization{}
    |> FestivalOrganization.changeset(%{
      name: "Test Org #{System.unique_integer([:positive])}",
      abbreviation: Keyword.fetch!(opts, :abbreviation)
    })
    |> Repo.insert!()
  end

  defp insert_ceremony!(org, opts) do
    %FestivalCeremony{
      organization_id: org.id,
      year: Keyword.fetch!(opts, :year),
      name: "#{org.name} #{Keyword.fetch!(opts, :year)}",
      data_source: "test"
    }
    |> Repo.insert!()
  end

  defp year_discovery_job_count do
    import Ecto.Query

    Repo.aggregate(
      from(j in Oban.Job, where: j.worker == "Cinegraph.Workers.YearDiscoveryWorker"),
      :count,
      :id
    )
  end

  defp unified_festival_job_count do
    import Ecto.Query

    Repo.aggregate(
      from(j in Oban.Job, where: j.worker == "Cinegraph.Workers.UnifiedFestivalWorker"),
      :count,
      :id
    )
  end
end
