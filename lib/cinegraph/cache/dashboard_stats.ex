defmodule Cinegraph.Cache.DashboardStats do
  @moduledoc """
  ETS-based cache for admin dashboard statistics.

  Uses async computation to prevent blocking/timeouts. Returns default values
  immediately and computes stats in the background.

  ## Usage

      # Get cached stats (returns defaults if not ready, triggers async compute)
      stats = DashboardStats.get_stats()

      # Force refresh (e.g., after import completes)
      DashboardStats.invalidate()
  """
  use GenServer
  require Logger

  alias Cinegraph.Repo
  alias Cinegraph.Movies.{Movie, MovieLists, Person, Credit, Genre, Keyword}
  alias Cinegraph.Collaborations.Collaboration

  alias Cinegraph.Festivals.{
    FestivalNomination,
    FestivalCeremony,
    FestivalCategory,
    FestivalOrganization
  }

  alias Cinegraph.Metrics.{ApiTracker, ApiLookupMetric}
  alias Cinegraph.Imports.{TMDbImporter, ImportStateV2}
  alias Cinegraph.Workers.{CanonicalImportOrchestrator, DailyYearImportWorker}
  import Ecto.Query

  @table_name :dashboard_stats_cache
  # Cache TTL: 60 seconds
  @cache_ttl_ms 60_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get cached dashboard stats. Returns immediately with defaults if not cached.
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
    Logger.info("DashboardStats cache initialized")
    # Start initial computation after a brief delay
    Process.send_after(self(), :initial_compute, 10_000)
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
        Logger.info("DashboardStats: Starting async computation")
        parent = self()

        Task.start(fn ->
          try do
            stats = compute_all_stats()
            send(parent, {:stats_computed, stats})
          rescue
            e ->
              Logger.error("DashboardStats: Computation failed: #{inspect(e)}")
              send(parent, :stats_computation_failed)
          end
        end)

        {:noreply, %{state | computing: true}}
    end
  end

  @impl true
  def handle_cast(:invalidate, state) do
    :ets.delete_all_objects(@table_name)
    Logger.info("DashboardStats: Cache invalidated")
    {:noreply, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    :ets.delete_all_objects(@table_name)
    Logger.info("DashboardStats: Cache invalidated, triggering refresh")
    # Trigger recomputation
    send(self(), :trigger_compute)
    {:noreply, state}
  end

  @impl true
  def handle_info(:initial_compute, state) do
    Logger.info("DashboardStats: Initial computation triggered")
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
    Logger.info("DashboardStats: Computation complete, caching results")
    cache_put(:all_stats, stats)
    # Broadcast to all connected clients that stats are ready
    Phoenix.PubSub.broadcast(Cinegraph.PubSub, "dashboard_stats", :stats_updated)
    {:noreply, %{state | computing: false}}
  end

  @impl true
  def handle_info(:stats_computation_failed, state) do
    Logger.warning("DashboardStats: Computation failed, will retry on next request")
    {:noreply, %{state | computing: false}}
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
      progress: %{our_total: 0, tmdb_total: 0, remaining: 0},
      db_stats: default_db_stats(),
      canonical_stats: [],
      oscar_stats: [],
      festival_stats: [],
      oban_stats: default_oban_stats(),
      runtime_stats: %{},
      api_metrics: %{},
      fallback_stats: %{},
      strategy_breakdown: [],
      import_metrics: [],
      year_progress: %{years: [], sync_health: %{}, current_year: nil, is_running: false},
      movie_lists: [],
      canonical_lists: [],
      loading: true
    }
  end

  defp default_db_stats do
    %{
      total_movies: 0,
      movies_with_tmdb: 0,
      movies_with_omdb: 0,
      canonical_movies: 0,
      festival_nominations: 0,
      festival_wins: 0,
      total_people: 0,
      directors_with_pqs: 0,
      actors_with_pqs: 0,
      total_credits: 0,
      total_genres: 0,
      total_keywords: 0,
      unique_collaborations: 0,
      multi_collaborations: 0
    }
  end

  defp default_oban_stats do
    queues = [
      :tmdb_orchestration,
      :tmdb_discovery,
      :tmdb_details,
      :omdb_enrichment,
      :collaboration,
      :imdb_scraping,
      :oscar_imports,
      :festival_import
    ]

    Enum.map(queues, fn queue ->
      %{name: queue, available: 0, executing: 0, completed: 0}
    end)
  end

  defp compute_all_stats do
    Logger.info("DashboardStats: Computing all stats...")

    # Compute in stages to help with debugging
    progress = safe_compute("progress", fn -> TMDbImporter.get_progress() end)
    db_stats = safe_compute("db_stats", &compute_db_stats/0)
    canonical_stats = safe_compute("canonical_stats", &compute_canonical_list_stats/0)
    oscar_stats = safe_compute("oscar_stats", &compute_oscar_stats/0)
    festival_stats = safe_compute("festival_stats", &compute_festival_stats/0)
    oban_stats = safe_compute("oban_stats", &compute_oban_stats/0)

    runtime_stats =
      safe_compute("runtime_stats", fn -> Cinegraph.Imports.ImportStats.get_stats() end)

    api_metrics = safe_compute("api_metrics", &compute_api_metrics/0)
    fallback_stats = safe_compute("fallback_stats", &compute_fallback_stats/0)
    strategy_breakdown = safe_compute("strategy_breakdown", &compute_strategy_breakdown/0)
    import_metrics = safe_compute("import_metrics", &compute_import_metrics/0)
    year_progress = safe_compute("year_progress", &compute_year_progress/0)
    movie_lists = safe_compute("movie_lists", &compute_movie_lists_with_counts/0)

    canonical_lists =
      safe_compute("canonical_lists", fn -> CanonicalImportOrchestrator.available_lists() end)

    Logger.info("DashboardStats: All stats computed successfully")

    %{
      progress: progress,
      db_stats: db_stats,
      canonical_stats: canonical_stats,
      oscar_stats: oscar_stats,
      festival_stats: festival_stats,
      oban_stats: oban_stats,
      runtime_stats: runtime_stats,
      api_metrics: api_metrics,
      fallback_stats: fallback_stats,
      strategy_breakdown: strategy_breakdown,
      import_metrics: import_metrics,
      year_progress: year_progress,
      movie_lists: movie_lists,
      canonical_lists: canonical_lists,
      loading: false
    }
  end

  defp safe_compute(name, fun) do
    try do
      Logger.debug("DashboardStats: Computing #{name}...")
      result = fun.()
      Logger.debug("DashboardStats: #{name} complete")
      result
    rescue
      e ->
        Logger.error("DashboardStats: Error computing #{name}: #{inspect(e)}")
        nil
    end
  end

  defp compute_db_stats do
    %{
      total_movies: Repo.aggregate(Movie, :count, :id),
      movies_with_tmdb:
        Repo.aggregate(from(m in Movie, where: not is_nil(m.tmdb_data)), :count, :id),
      movies_with_omdb:
        Repo.aggregate(from(m in Movie, where: not is_nil(m.omdb_data)), :count, :id),
      canonical_movies: compute_canonical_movies_count(),
      festival_nominations: compute_festival_nominations_count(),
      festival_wins: compute_festival_wins_count(),
      total_people: Repo.aggregate(Person, :count, :id),
      directors_with_pqs: compute_directors_with_pqs_count(),
      actors_with_pqs: compute_actors_with_pqs_count(),
      total_credits: Repo.aggregate(Credit, :count, :id),
      total_genres: Repo.aggregate(Genre, :count, :id),
      total_keywords: Repo.aggregate(Keyword, :count, :id),
      unique_collaborations: Repo.aggregate(Collaboration, :count, :id),
      multi_collaborations:
        Repo.aggregate(
          from(c in Collaboration, where: c.collaboration_count > 1),
          :count
        )
    }
  end

  defp compute_oban_stats do
    queues = [
      :tmdb_orchestration,
      :tmdb_discovery,
      :tmdb_details,
      :omdb_enrichment,
      :collaboration,
      :imdb_scraping,
      :oscar_imports,
      :festival_import
    ]

    # Batch query - get all queue/state combinations in one query
    results =
      Repo.all(
        from(j in Oban.Job,
          where:
            j.queue in ^Enum.map(queues, &to_string/1) and
              j.state in ["available", "executing", "completed"],
          group_by: [j.queue, j.state],
          select: {j.queue, j.state, count(j.id)}
        )
      )

    # Build map of results
    results_map =
      results
      |> Enum.reduce(%{}, fn {queue, state, count}, acc ->
        queue_atom = String.to_existing_atom(queue)
        Map.update(acc, queue_atom, %{state => count}, &Map.put(&1, state, count))
      end)

    # Format for each queue - return maps with :name key for template compatibility
    Enum.map(queues, fn queue ->
      queue_data = Map.get(results_map, queue, %{})

      %{
        name: queue,
        available: Map.get(queue_data, "available", 0),
        executing: Map.get(queue_data, "executing", 0),
        completed: Map.get(queue_data, "completed", 0)
      }
    end)
  end

  defp compute_oscar_stats do
    oscar_org = Cinegraph.Festivals.get_or_create_oscar_organization()

    if oscar_org && oscar_org.id do
      ceremony_stats =
        Repo.all(
          from fc in FestivalCeremony,
            left_join: nom in FestivalNomination,
            on: nom.ceremony_id == fc.id,
            where: fc.organization_id == ^oscar_org.id,
            group_by: [fc.year, fc.id],
            select:
              {fc.year, count(nom.id), sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", nom.won))},
            order_by: [desc: fc.year]
        )

      total_nominations =
        Enum.sum(Enum.map(ceremony_stats, fn {_year, nominations, _wins} -> nominations end))

      total_wins =
        Enum.sum(Enum.map(ceremony_stats, fn {_year, _nominations, wins} -> wins || 0 end))

      total_ceremonies = length(ceremony_stats)

      total_categories =
        Repo.aggregate(
          from(c in FestivalCategory, where: c.organization_id == ^oscar_org.id),
          :count
        )

      people_noms_query =
        from nom in FestivalNomination,
          join: fc in FestivalCategory,
          on: nom.category_id == fc.id,
          join: cer in FestivalCeremony,
          on: nom.ceremony_id == cer.id,
          where: fc.tracks_person == true and cer.organization_id == ^oscar_org.id

      people_nominations = Repo.aggregate(people_noms_query, :count, :id) || 0

      people_nominations_linked =
        Repo.aggregate(
          from(q in people_noms_query, where: not is_nil(q.person_id)),
          :count,
          :id
        ) || 0

      people_nominations_display =
        if people_nominations == 0 do
          "0"
        else
          if people_nominations_linked == people_nominations do
            "#{format_number(people_nominations)} ✅"
          else
            linking_rate =
              if people_nominations > 0,
                do: Float.round(people_nominations_linked / people_nominations * 100, 1),
                else: 0.0

            "#{format_number(people_nominations_linked)}/#{format_number(people_nominations)} (#{linking_rate}%)"
          end
        end

      base_stats = [
        %{label: "Oscar Ceremonies", value: "#{total_ceremonies}"},
        %{label: "Oscar Nominations", value: format_number(total_nominations)},
        %{label: "Oscar Wins", value: format_number(total_wins)},
        %{label: "Oscar Categories", value: format_number(total_categories)},
        %{label: "People Nominations", value: people_nominations_display}
      ]

      year_stats =
        ceremony_stats
        |> Enum.filter(fn {_year, nominations, _wins} -> nominations > 0 end)
        |> Enum.take(5)
        |> Enum.map(fn {year, nominations, wins} ->
          %{label: "Oscars #{year}", value: "#{wins || 0}/#{nominations}"}
        end)

      base_stats ++ year_stats
    else
      []
    end
  end

  defp compute_festival_stats do
    festival_orgs =
      Repo.all(
        from fo in FestivalOrganization,
          where: fo.abbreviation != "AMPAS",
          select: fo
      )

    all_stats =
      festival_orgs
      |> Enum.flat_map(fn org ->
        ceremony_stats =
          Repo.all(
            from fc in FestivalCeremony,
              left_join: nom in FestivalNomination,
              on: nom.ceremony_id == fc.id,
              where: fc.organization_id == ^org.id,
              group_by: [fc.year, fc.id],
              select:
                {fc.year, count(nom.id), sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", nom.won))},
              order_by: [desc: fc.year]
          )

        if length(ceremony_stats) > 0 do
          total_nominations =
            Enum.sum(Enum.map(ceremony_stats, fn {_year, nominations, _wins} -> nominations end))

          total_wins =
            Enum.sum(Enum.map(ceremony_stats, fn {_year, _nominations, wins} -> wins || 0 end))

          total_ceremonies = length(ceremony_stats)

          total_categories =
            Repo.aggregate(
              from(c in FestivalCategory, where: c.organization_id == ^org.id),
              :count
            )

          people_nominations =
            Repo.one(
              from nom in FestivalNomination,
                join: fc in FestivalCategory,
                on: nom.category_id == fc.id,
                join: cer in FestivalCeremony,
                on: nom.ceremony_id == cer.id,
                where: fc.tracks_person == true and cer.organization_id == ^org.id,
                select: count(nom.id)
            ) || 0

          people_nominations_linked =
            Repo.one(
              from nom in FestivalNomination,
                join: fc in FestivalCategory,
                on: nom.category_id == fc.id,
                join: cer in FestivalCeremony,
                on: nom.ceremony_id == cer.id,
                where:
                  fc.tracks_person == true and cer.organization_id == ^org.id and
                    not is_nil(nom.person_id),
                select: count(nom.id)
            ) || 0

          people_nominations_display =
            if people_nominations == 0 do
              "0"
            else
              if people_nominations_linked == people_nominations do
                "#{format_number(people_nominations)} ✅"
              else
                linking_rate =
                  if people_nominations > 0,
                    do: Float.round(people_nominations_linked / people_nominations * 100, 1),
                    else: 0.0

                "#{format_number(people_nominations_linked)}/#{format_number(people_nominations)} (#{linking_rate}%)"
              end
            end

          festival_name =
            case org.abbreviation do
              "VIFF" -> "Venice"
              "CFF" -> "Cannes"
              "BIFF" -> "Berlin"
              _ -> org.name
            end

          base_stats = [
            %{label: "#{festival_name} Ceremonies", value: "#{total_ceremonies}"},
            %{label: "#{festival_name} Nominations", value: format_number(total_nominations)},
            %{label: "#{festival_name} Wins", value: format_number(total_wins)},
            %{label: "#{festival_name} Categories", value: format_number(total_categories)},
            %{label: "#{festival_name} People Nominations", value: people_nominations_display}
          ]

          year_stats =
            ceremony_stats
            |> Enum.filter(fn {_year, nominations, _wins} -> nominations > 0 end)
            |> Enum.take(3)
            |> Enum.map(fn {year, nominations, wins} ->
              %{
                label: "#{festival_name} #{year}",
                value: "#{wins || 0}/#{nominations}"
              }
            end)

          base_stats ++ year_stats
        else
          []
        end
      end)

    if length(all_stats) > 0, do: all_stats, else: []
  end

  defp compute_api_metrics do
    ApiTracker.get_all_stats(24)
    |> Enum.group_by(& &1.source)
    |> Enum.map(fn {source, operations} ->
      total_calls = Enum.sum(Enum.map(operations, & &1.total))
      total_successful = Enum.sum(Enum.map(operations, &(&1.successful || 0)))

      avg_response_time =
        if total_calls > 0 do
          total_response_time =
            Enum.sum(
              Enum.map(operations, fn op ->
                avg_time =
                  case op.avg_response_time do
                    %Decimal{} = decimal -> Decimal.to_float(decimal)
                    nil -> 0
                    value -> value
                  end

                avg_time * op.total
              end)
            )

          Float.round(total_response_time / total_calls, 0)
        else
          0
        end

      success_rate =
        if total_calls > 0, do: Float.round(total_successful / total_calls * 100, 1), else: 0.0

      {source,
       %{
         total_calls: total_calls,
         success_rate: success_rate,
         avg_response_time: avg_response_time,
         operations: operations
       }}
    end)
    |> Enum.into(%{})
  end

  defp compute_fallback_stats do
    ApiTracker.get_tmdb_fallback_stats(24)
    |> Enum.map(fn stat ->
      avg_conf =
        case stat.avg_confidence do
          %Decimal{} = d -> Decimal.to_float(d)
          nil -> 0.0
          v when is_number(v) -> v
        end

      {stat.level,
       %{
         total: stat.total,
         successful: stat.successful || 0,
         success_rate: stat.success_rate || 0.0,
         avg_confidence: Float.round(avg_conf, 2)
       }}
    end)
    |> Enum.into(%{})
  end

  defp compute_strategy_breakdown do
    ApiTracker.get_tmdb_strategy_breakdown(24)
  end

  defp compute_import_metrics do
    since = DateTime.utc_now() |> DateTime.add(-24 * 3600, :second)

    Repo.all(
      from m in ApiLookupMetric,
        where: m.operation == "import_state" and m.inserted_at >= ^since,
        order_by: [desc: m.inserted_at],
        limit: 10,
        select: %{
          source: m.source,
          key: m.target_identifier,
          metadata: m.metadata,
          inserted_at: m.inserted_at
        }
    )
  end

  defp compute_year_progress do
    current_year = Date.utc_today().year
    last_completed_year = ImportStateV2.get_integer("last_completed_year", current_year + 1)
    current_import_year = ImportStateV2.get("current_import_year")
    bulk_complete = ImportStateV2.get("bulk_import_complete")

    is_running = check_year_import_running()

    years =
      if bulk_complete do
        []
      else
        start_year = current_year
        end_year = max(last_completed_year - 1, current_year - 10)

        start_year..end_year
        |> Enum.map(fn year ->
          our_count = DailyYearImportWorker.count_movies_for_year(year)
          tmdb_count = ImportStateV2.get_integer("year_#{year}_total_movies", 0)
          progress_pct = ImportStateV2.get("year_#{year}_progress")

          status =
            cond do
              year > last_completed_year -> :pending
              year == last_completed_year -> :pending
              year == current_import_year -> :in_progress
              year < last_completed_year -> :completed
              true -> :pending
            end

          %{
            year: year,
            our_count: our_count,
            tmdb_count: tmdb_count,
            progress: progress_pct,
            status: status,
            started_at: ImportStateV2.get("year_#{year}_started_at"),
            completed_at: ImportStateV2.get("year_#{year}_completed_at")
          }
        end)
      end

    sync_health = calculate_sync_health(last_completed_year, current_year, bulk_complete)

    %{
      years: years,
      sync_health: sync_health,
      current_year: current_import_year,
      is_running: is_running
    }
  end

  defp check_year_import_running do
    count =
      Repo.one(
        from(j in Oban.Job,
          where:
            j.worker == "Cinegraph.Workers.DailyYearImportWorker" and
              j.state in ["available", "executing", "scheduled"],
          select: count(j.id)
        )
      ) || 0

    count > 0
  end

  defp calculate_sync_health(last_completed_year, current_year, bulk_complete) do
    cond do
      bulk_complete ->
        %{
          status: :complete,
          message: "Full catalog imported! Ready for daily delta sync.",
          color: "green"
        }

      last_completed_year > current_year ->
        %{
          status: :not_started,
          message: "Year-by-year import not yet started.",
          color: "gray"
        }

      last_completed_year == current_year ->
        %{
          status: :starting,
          message: "Starting year-by-year import from #{current_year}.",
          color: "blue"
        }

      last_completed_year >= current_year - 5 ->
        years_done = current_year - last_completed_year + 1

        %{
          status: :in_progress,
          message: "#{years_done} years imported (#{last_completed_year + 1}-#{current_year}).",
          color: "blue"
        }

      true ->
        years_done = current_year - last_completed_year + 1

        %{
          status: :in_progress,
          message: "#{years_done} years imported. Working on #{last_completed_year}.",
          color: "yellow"
        }
    end
  end

  defp compute_canonical_list_stats do
    MovieLists.list_all_movie_lists()
    |> Enum.map(fn list ->
      count =
        case Repo.query("SELECT COUNT(*) FROM movies WHERE canonical_sources ? $1", [
               list.source_key
             ]) do
          {:ok, %{rows: [[c]]}} -> c
          _ -> 0
        end

      %{
        name: list.name,
        source_key: list.source_key,
        our_count: count,
        expected_count: list.expected_count,
        category: list.category
      }
    end)
  end

  defp compute_movie_lists_with_counts do
    MovieLists.list_all_movie_lists()
    |> Enum.map(fn list ->
      real_count =
        case Repo.query("SELECT COUNT(*) FROM movies WHERE canonical_sources ? $1", [
               list.source_key
             ]) do
          {:ok, %{rows: [[count]]}} -> count
          _ -> 0
        end

      Map.put(list, :real_movie_count, real_count)
    end)
  end

  defp compute_canonical_movies_count do
    active_source_keys = MovieLists.get_active_source_keys()

    if length(active_source_keys) > 0 do
      Repo.aggregate(
        from(m in Movie, where: fragment("? \\?| ?", m.canonical_sources, ^active_source_keys)),
        :count
      )
    else
      0
    end
  end

  defp compute_festival_nominations_count do
    Repo.one(
      from n in FestivalNomination,
        where: not is_nil(n.movie_id),
        select: count(n.movie_id, :distinct)
    ) || 0
  end

  defp compute_festival_wins_count do
    Repo.one(
      from n in FestivalNomination,
        where: not is_nil(n.movie_id) and n.won == true,
        select: count(n.movie_id, :distinct)
    ) || 0
  end

  defp compute_directors_with_pqs_count do
    Repo.one(
      from pm in Cinegraph.Metrics.PersonMetric,
        join: p in Person,
        on: pm.person_id == p.id,
        join: c in Credit,
        on: c.person_id == p.id,
        where: c.job == "Director",
        select: count(p.id, :distinct)
    ) || 0
  end

  defp compute_actors_with_pqs_count do
    Repo.one(
      from pm in Cinegraph.Metrics.PersonMetric,
        join: p in Person,
        on: pm.person_id == p.id,
        join: c in Credit,
        on: c.person_id == p.id,
        where: c.department == "Acting",
        select: count(p.id, :distinct)
    ) || 0
  end

  defp format_number(num) when is_integer(num) do
    num
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_number(num), do: to_string(num)
end
