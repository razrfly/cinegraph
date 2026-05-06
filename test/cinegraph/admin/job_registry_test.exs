defmodule Cinegraph.Admin.JobRegistryTest do
  use ExUnit.Case, async: true

  alias Cinegraph.Admin.JobRegistry

  @moduledoc """
  The "parity test" below is the structural fix for the drift bug found
  during the issue #880 audit: when admin tables hand-code from `config.exs`,
  they silently desync as new workers land. By generating the admin tables
  from `JobRegistry` and asserting `JobRegistry.scheduled/0` matches
  `config.exs`'s crontab on every CI build, we make drift impossible.

  If you add a cron entry to `config/config.exs` and this test fails:
  add a matching entry to `lib/cinegraph/admin/job_registry.ex`.
  """

  describe "parity with config.exs Oban crontab" do
    test "every cron entry in config.exs is registered in JobRegistry" do
      cron_entries = oban_cron_entries()

      registered =
        JobRegistry.scheduled()
        |> Enum.map(&{&1.worker, &1.schedule, &1.args})

      missing =
        for {schedule, worker, opts} <- cron_entries,
            args = Keyword.get(opts, :args, %{}),
            {worker, schedule, args} not in registered do
          %{worker: worker, schedule: schedule, args: args}
        end

      assert missing == [], """
      Cron entries in config.exs are not registered in JobRegistry:

      #{Enum.map_join(missing, "\n", &"  #{inspect(&1)}")}

      Add matching entries to lib/cinegraph/admin/job_registry.ex.
      """
    end

    test "every JobRegistry scheduled entry maps to a real cron entry" do
      cron_entries = oban_cron_entries()

      cron_keys =
        for {schedule, worker, opts} <- cron_entries,
            do: {worker, schedule, Keyword.get(opts, :args, %{})}

      orphans =
        for entry <- JobRegistry.scheduled(),
            {entry.worker, entry.schedule, entry.args} not in cron_keys do
          %{
            id: entry.id,
            worker: entry.worker,
            schedule: entry.schedule,
            args: entry.args
          }
        end

      assert orphans == [], """
      JobRegistry has scheduled entries that don't match any cron entry in config.exs:

      #{Enum.map_join(orphans, "\n", &"  #{inspect(&1)}")}

      Either remove these from JobRegistry or add the matching cron entry to config.exs.
      """
    end

    test "scheduled count matches config.exs cron count" do
      cron_entries = oban_cron_entries()
      registered = JobRegistry.scheduled()

      assert length(registered) == length(cron_entries),
             """
             JobRegistry.scheduled/0 has #{length(registered)} entries; \
             config.exs crontab has #{length(cron_entries)}. The numbers must match.
             """
    end
  end

  describe "entry shape" do
    test "every entry has all required keys with correct types" do
      for entry <- JobRegistry.all() do
        assert is_atom(entry.id), "id must be atom: #{inspect(entry)}"
        assert is_binary(entry.label), "label must be string: #{inspect(entry.id)}"

        assert is_atom(entry.worker) and Code.ensure_loaded?(entry.worker),
               "worker module not loadable: #{inspect(entry.worker)} for id #{inspect(entry.id)}"

        assert is_atom(entry.queue), "queue must be atom: #{inspect(entry.id)}"

        assert entry.schedule == nil or is_binary(entry.schedule),
               "schedule must be nil or string: #{inspect(entry.id)}"

        assert is_map(entry.args), "args must be a map: #{inspect(entry.id)}"

        assert entry.trigger_action in [:enqueue_now, :run_inline, :disabled],
               "trigger_action must be a known atom: #{inspect(entry.id)}"

        assert is_boolean(entry.mutating), "mutating must be a boolean: #{inspect(entry.id)}"

        assert is_binary(entry.description) and entry.description != "",
               "description must be a non-empty string: #{inspect(entry.id)}"

        assert is_atom(entry.destination), "destination must be an atom: #{inspect(entry.id)}"
        assert entry.doc_url == nil or is_binary(entry.doc_url)
      end
    end

    test "ids are unique across all entries" do
      ids = JobRegistry.all() |> Enum.map(& &1.id)
      duplicates = ids -- Enum.uniq(ids)

      assert duplicates == [], """
      Duplicate ids found in JobRegistry: #{inspect(duplicates)}.
      Each entry's id must be unique because the URL routes through it (/admin/scheduled/:id).
      """
    end
  end

  describe "filters" do
    test "scheduled/0 only returns entries with a non-nil schedule" do
      assert Enum.all?(JobRegistry.scheduled(), &(&1.schedule != nil))
    end

    test "on_demand/0 only returns entries with a nil schedule" do
      assert Enum.all?(JobRegistry.on_demand(), &(&1.schedule == nil))
    end

    test "scheduled/0 + on_demand/0 == all/0" do
      assert length(JobRegistry.scheduled()) + length(JobRegistry.on_demand()) ==
               length(JobRegistry.all())
    end

    test "by_id/1 returns nil for unknown id" do
      assert JobRegistry.by_id(:no_such_id) == nil
    end

    test "by_id/1 returns the entry for a known id" do
      entry = JobRegistry.by_id(:biography_refresh_sweeper)

      assert %{id: :biography_refresh_sweeper, worker: Cinegraph.Workers.BiographyRefreshSweeper} =
               entry
    end

    test "by_destination/1 returns entries matching the domain" do
      people_entries = JobRegistry.by_destination(:people)
      assert Enum.all?(people_entries, &(&1.destination == :people))
      assert Enum.any?(people_entries, &(&1.id == :biography_refresh_sweeper))
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp oban_cron_entries do
    plugins = Application.get_env(:cinegraph, Oban)[:plugins]

    {Oban.Plugins.Cron, cron_opts} =
      Enum.find(plugins, &match?({Oban.Plugins.Cron, _}, &1))

    Keyword.fetch!(cron_opts, :crontab)
    |> Enum.map(fn
      {schedule, worker} -> {schedule, worker, []}
      {schedule, worker, opts} -> {schedule, worker, opts}
    end)
  end
end
