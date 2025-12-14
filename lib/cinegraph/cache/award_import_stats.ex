defmodule Cinegraph.Cache.AwardImportStats do
  @moduledoc """
  ETS-based cache for award import dashboard statistics.

  Uses async computation to prevent blocking/timeouts. Returns default values
  immediately and computes stats in the background.

  ## Usage

      # Get cached stats (returns defaults if not ready, triggers async compute)
      stats = AwardImportStats.get_stats()

      # Force refresh (e.g., after import completes)
      AwardImportStats.invalidate()

      # Get stats for a specific organization
      org_stats = AwardImportStats.get_organization_stats(org_id)
  """
  use GenServer
  require Logger

  alias Cinegraph.Repo
  alias Cinegraph.Festivals
  alias Cinegraph.Festivals.AwardImportStatus
  import Ecto.Query

  @table_name :award_import_stats_cache
  # Cache TTL: 60 seconds
  @cache_ttl_ms 60_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get cached award import stats. Returns immediately with defaults if not cached.
  Triggers async computation if cache is stale/missing.
  """
  def get_stats do
    case get_cached(:all_stats) do
      {:ok, stats} ->
        stats

      :miss ->
        # Trigger async computation
        GenServer.cast(__MODULE__, :compute_async)
        # Return defaults immediately so page loads
        default_stats()
    end
  end

  @doc """
  Get stats for a specific organization by ID.
  """
  def get_organization_stats(organization_id) do
    stats = get_stats()

    Enum.find(stats.organizations, fn org ->
      org.organization_id == organization_id
    end)
  end

  @doc """
  Get year details for a specific organization.
  """
  def get_organization_years(organization_id) do
    case get_cached({:org_years, organization_id}) do
      {:ok, years} ->
        years

      :miss ->
        # Trigger async computation for this specific org
        GenServer.cast(__MODULE__, {:compute_org_years_async, organization_id})
        # Return empty list while computing
        []
    end
  end

  @doc """
  Check if stats are currently being computed.
  """
  def computing? do
    GenServer.call(__MODULE__, :computing?)
  end

  @doc """
  Invalidate all cached stats. Call after imports complete.
  """
  def invalidate do
    GenServer.cast(__MODULE__, :invalidate)
  end

  @doc """
  Invalidate and immediately trigger recomputation.
  """
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table owned by this process
    table = :ets.new(@table_name, [:set, :protected, :named_table])
    Logger.info("AwardImportStats cache initialized")
    # Start initial computation after a brief delay
    Process.send_after(self(), :initial_compute, 15_000)
    {:ok, %{table: table, computing: false}}
  end

  @impl true
  def handle_call(:computing?, _from, state) do
    {:reply, state.computing, state}
  end

  @impl true
  def handle_cast(:compute_async, %{computing: true} = state) do
    # Already computing, skip
    {:noreply, state}
  end

  @impl true
  def handle_cast(:compute_async, state) do
    # Check cache again before starting computation
    case get_cached(:all_stats) do
      {:ok, _stats} ->
        {:noreply, state}

      :miss ->
        # Start async computation
        Logger.info("AwardImportStats: Starting async computation")
        parent = self()

        Task.start(fn ->
          try do
            stats = compute_all_stats()
            send(parent, {:stats_computed, stats})
          rescue
            e ->
              Logger.error("AwardImportStats: Computation failed: #{inspect(e)}")
              send(parent, :stats_computation_failed)
          end
        end)

        {:noreply, %{state | computing: true}}
    end
  end

  @impl true
  def handle_cast({:compute_org_years_async, organization_id}, state) do
    # Check cache before starting computation
    case get_cached({:org_years, organization_id}) do
      {:ok, _years} ->
        {:noreply, state}

      :miss ->
        Logger.info("AwardImportStats: Computing years for organization #{organization_id}")
        parent = self()

        Task.start(fn ->
          try do
            years = compute_organization_years(organization_id)
            send(parent, {:org_years_computed, organization_id, years})
          rescue
            e ->
              Logger.error(
                "AwardImportStats: Org years computation failed for #{organization_id}: #{inspect(e)}"
              )
          end
        end)

        {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:invalidate, state) do
    :ets.delete_all_objects(@table_name)
    Logger.info("AwardImportStats: Cache invalidated")
    # Broadcast invalidation to connected clients
    Phoenix.PubSub.broadcast(Cinegraph.PubSub, "award_imports", :cache_invalidated)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    :ets.delete_all_objects(@table_name)
    Logger.info("AwardImportStats: Cache invalidated, triggering refresh")
    # Trigger recomputation
    send(self(), :trigger_compute)
    {:noreply, state}
  end

  @impl true
  def handle_info(:initial_compute, state) do
    Logger.info("AwardImportStats: Initial computation triggered")
    GenServer.cast(self(), :compute_async)
    {:noreply, state}
  end

  @impl true
  def handle_info(:trigger_compute, state) do
    GenServer.cast(self(), :compute_async)
    {:noreply, state}
  end

  @impl true
  def handle_info({:stats_computed, stats}, state) do
    Logger.info("AwardImportStats: Computation complete, caching results")
    cache_put(:all_stats, stats)
    # Broadcast to all connected clients that stats are ready
    Phoenix.PubSub.broadcast(Cinegraph.PubSub, "award_imports", :stats_updated)
    {:noreply, %{state | computing: false}}
  end

  @impl true
  def handle_info(:stats_computation_failed, state) do
    Logger.warning("AwardImportStats: Computation failed, will retry on next request")
    {:noreply, %{state | computing: false}}
  end

  @impl true
  def handle_info({:org_years_computed, organization_id, years}, state) do
    Logger.info("AwardImportStats: Org years computed for #{organization_id}")
    cache_put({:org_years, organization_id}, years)
    # Broadcast update for this organization
    Phoenix.PubSub.broadcast(
      Cinegraph.PubSub,
      "award_imports",
      {:org_years_updated, organization_id}
    )

    {:noreply, state}
  end

  # Private Functions

  defp get_cached(key) do
    case :ets.lookup(@table_name, key) do
      [{^key, data, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, data}
        else
          :miss
        end

      [] ->
        :miss
    end
  end

  defp cache_put(key, data) do
    expires_at = System.monotonic_time(:millisecond) + @cache_ttl_ms
    :ets.insert(@table_name, {key, data, expires_at})
  end

  defp default_stats do
    %{
      overall: %{
        total_ceremonies: 0,
        total_organizations: 0,
        completed_count: 0,
        partial_count: 0,
        pending_count: 0,
        failed_count: 0,
        no_data_count: 0,
        completion_percentage: 0.0,
        total_nominations: 0,
        total_matched: 0,
        avg_match_rate: 0.0
      },
      organizations: [],
      queue_status: %{
        available: 0,
        executing: 0,
        completed: 0,
        failed: 0
      },
      recent_activity: [],
      loading: true
    }
  end

  defp compute_all_stats do
    Logger.info("AwardImportStats: Computing all stats...")

    overall = safe_compute("overall", &compute_overall_stats/0)
    organizations = safe_compute("organizations", &compute_organization_summaries/0)
    queue_status = safe_compute("queue_status", &compute_queue_status/0)
    recent_activity = safe_compute("recent_activity", &compute_recent_activity/0)

    Logger.info("AwardImportStats: All stats computed successfully")

    %{
      overall: overall || default_stats().overall,
      organizations: organizations || [],
      queue_status: queue_status || default_stats().queue_status,
      recent_activity: recent_activity || [],
      loading: false
    }
  end

  defp safe_compute(name, fun) do
    try do
      Logger.debug("AwardImportStats: Computing #{name}...")
      result = fun.()
      Logger.debug("AwardImportStats: #{name} complete")
      result
    rescue
      e ->
        Logger.error("AwardImportStats: Error computing #{name}: #{inspect(e)}")
        nil
    end
  end

  defp compute_overall_stats do
    # Use the award_import_status view for all stats
    statuses = Festivals.list_award_import_statuses()

    # Total years includes ALL rows from the view (not just imported ones)
    total_years = length(statuses)
    total_ceremonies = Enum.count(statuses, fn s -> s.ceremony_id != nil end)
    total_organizations = statuses |> Enum.map(& &1.organization_id) |> Enum.uniq() |> length()

    # Count by status
    completed_count = Enum.count(statuses, fn s -> s.status == "completed" end)
    partial_count = Enum.count(statuses, fn s -> s.status == "partial" end)
    pending_count = Enum.count(statuses, fn s -> s.status in ["not_started", "pending"] end)

    # Separate no_data (IMDb 404) from actual failures
    no_data_count = Enum.count(statuses, fn s -> s.status in ["no_data", "empty"] end)

    # Failed count excludes no_data - these are actual import failures that need attention
    failed_count =
      Enum.count(statuses, fn s -> s.status in ["failed", "no_matches", "low_match"] end)

    # Calculate totals (using actual schema field names)
    total_nominations = Enum.sum(Enum.map(statuses, fn s -> s.total_nominations || 0 end))
    total_matched = Enum.sum(Enum.map(statuses, fn s -> s.matched_movies || 0 end))

    avg_match_rate =
      if total_nominations > 0 do
        Float.round(total_matched / total_nominations * 100, 1)
      else
        0.0
      end

    # Completion percentage includes completed + no_data (these are "done" in the sense that
    # there's nothing more we can do with them)
    completion_percentage =
      if total_years > 0 do
        Float.round((completed_count + no_data_count) / total_years * 100, 1)
      else
        0.0
      end

    %{
      total_ceremonies: total_ceremonies,
      total_organizations: total_organizations,
      completed_count: completed_count,
      partial_count: partial_count,
      pending_count: pending_count,
      failed_count: failed_count,
      no_data_count: no_data_count,
      completion_percentage: completion_percentage,
      total_nominations: total_nominations,
      total_matched: total_matched,
      avg_match_rate: avg_match_rate
    }
  end

  defp compute_organization_summaries do
    # Get all statuses and group by organization
    statuses = Festivals.list_award_import_statuses()

    statuses
    |> Enum.group_by(& &1.organization_id)
    |> Enum.map(fn {org_id, org_statuses} ->
      first_status = List.first(org_statuses)

      # Count statuses
      total_years = length(org_statuses)
      imported_years = Enum.count(org_statuses, fn s -> s.ceremony_id != nil end)
      completed_count = Enum.count(org_statuses, fn s -> s.status == "completed" end)
      partial_count = Enum.count(org_statuses, fn s -> s.status == "partial" end)
      pending_count = Enum.count(org_statuses, fn s -> s.status in ["not_started", "pending"] end)

      # Separate no_data (IMDb 404) from actual failures
      no_data_count = Enum.count(org_statuses, fn s -> s.status in ["no_data", "empty"] end)

      failed_count =
        Enum.count(org_statuses, fn s ->
          s.status in ["failed", "no_matches", "low_match"]
        end)

      # Calculate totals
      total_nominations = Enum.sum(Enum.map(org_statuses, fn s -> s.total_nominations || 0 end))
      total_matched = Enum.sum(Enum.map(org_statuses, fn s -> s.matched_movies || 0 end))

      avg_match_rate =
        if total_nominations > 0 do
          Float.round(total_matched / total_nominations * 100, 1)
        else
          0.0
        end

      # Get year range
      years = Enum.map(org_statuses, & &1.year) |> Enum.reject(&is_nil/1)
      year_range = if length(years) > 0, do: "#{Enum.min(years)}-#{Enum.max(years)}", else: "N/A"

      # Get data source from the view data (already has default_source from known_festivals)
      data_source =
        org_statuses
        |> Enum.map(& &1.data_source)
        |> Enum.reject(&is_nil/1)
        |> Enum.frequencies()
        |> Enum.max_by(fn {_source, count} -> count end, fn -> {"unknown", 0} end)
        |> elem(0)

      %{
        organization_id: org_id,
        organization_name: first_status.organization_name,
        abbreviation: first_status.abbreviation,
        total_years: total_years,
        imported_years: imported_years,
        completed_count: completed_count,
        partial_count: partial_count,
        pending_count: pending_count,
        failed_count: failed_count,
        no_data_count: no_data_count,
        total_nominations: total_nominations,
        total_matched: total_matched,
        avg_match_rate: avg_match_rate,
        year_range: year_range,
        data_source: data_source
      }
    end)
    |> Enum.sort_by(& &1.organization_name)
  end

  defp compute_queue_status do
    # Query Oban jobs for festival_import queue
    results =
      Repo.all(
        from(j in Oban.Job,
          where:
            j.queue == "festival_import" and
              j.state in ["available", "executing", "completed", "discarded"],
          group_by: j.state,
          select: {j.state, count(j.id)}
        )
      )
      |> Enum.into(%{})

    %{
      available: Map.get(results, "available", 0),
      executing: Map.get(results, "executing", 0),
      completed: Map.get(results, "completed", 0),
      failed: Map.get(results, "discarded", 0)
    }
  end

  defp compute_recent_activity do
    # Get recent ceremonies with import activity
    since = DateTime.utc_now() |> DateTime.add(-24 * 3600, :second)

    query =
      from(s in AwardImportStatus,
        where: not is_nil(s.scraped_at) and s.scraped_at >= ^since,
        order_by: [desc: s.scraped_at],
        limit: 20,
        select: %{
          organization_name: s.organization_name,
          abbreviation: s.abbreviation,
          year: s.year,
          status: s.status,
          total_nominations: s.total_nominations,
          movie_match_rate: s.movie_match_rate,
          scraped_at: s.scraped_at
        }
      )

    Repo.all(query)
  end

  defp compute_organization_years(organization_id) do
    # Get all years for a specific organization
    Festivals.list_award_import_statuses(organization_id: organization_id)
    |> Enum.sort_by(& &1.year, :desc)
    |> Enum.map(fn status ->
      # Extract error info from source_metadata if available
      error_info = extract_error_from_metadata(status.source_metadata)

      %{
        year: status.year,
        ceremony_id: status.ceremony_id,
        status: status.status,
        data_source: status.data_source,
        scraped_at: status.scraped_at,
        total_nominations: status.total_nominations || 0,
        matched_movies: status.matched_movies || 0,
        winners: status.winners || 0,
        movie_match_rate: decimal_to_float(status.movie_match_rate),
        last_error: error_info[:last_error],
        retry_count: error_info[:retry_count] || 0,
        job_id: error_info[:job_id]
      }
    end)
  end

  defp extract_error_from_metadata(nil), do: %{}

  defp extract_error_from_metadata(metadata) when is_map(metadata) do
    %{
      last_error: metadata["last_error"],
      retry_count: metadata["retry_count"],
      job_id: metadata["job_id"]
    }
  end

  defp extract_error_from_metadata(_), do: %{}

  defp decimal_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_to_float(nil), do: 0.0
  defp decimal_to_float(value) when is_number(value), do: value
  defp decimal_to_float(_), do: 0.0
end
