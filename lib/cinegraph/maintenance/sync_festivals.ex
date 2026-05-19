defmodule Cinegraph.Maintenance.SyncFestivals do
  @moduledoc """
  Monthly festival sync (#745 Phase 2). For every active `FestivalEvent`:

  1. **Discovery pass** — enqueue `YearDiscoveryWorker` so the upstream
     source's available-years list lands in `festival_events.discovered_years`.
  2. **Import pass** — diff `discovered_years` against existing
     `festival_ceremonies.year` rows for that event's organization, then
     call `Cinegraph.Cultural.import_festival_year/2` for every missing year.

  Reachable from:
  - `Cinegraph.Workers.FestivalSyncSweeper` (Oban Cron `0 2 1 * *`,
    monthly at 02:00 UTC on the 1st)
  - `mix cinegraph.festivals.sync` (dev / ad-hoc)
  - `bin/cinegraph eval "Cinegraph.Maintenance.SyncFestivals.run([])"` (one-shot)

  ## Race semantics

  The discovery pass enqueues async jobs; the import pass reads
  `discovered_years` as it currently exists in the DB. Worst-case lag from
  "new year appears upstream" → "ceremony imported" is roughly **one month**
  (this month's discovery → next month's import). Acceptable.

  ## Options

    * `:dry_run` (boolean) — skip both passes' enqueues; report counts only.

  ## Returns

  `{:ok, %{events, discoveries_enqueued, discoveries_already_queued, imports_enqueued, imports_already_queued, failed, dry_run}}`

  Both `*_already_queued` counters reflect Oban uniqueness rejections — a
  benign no-op when the same source/key has already been enqueued in the
  uniqueness window. They are NOT failures.
  """

  alias Cinegraph.{Cultural, Events, Repo}
  alias Cinegraph.Workers.YearDiscoveryWorker

  import Ecto.Query
  require Logger

  @spec run(keyword()) ::
          {:ok,
           %{
             events: non_neg_integer(),
             discoveries_enqueued: non_neg_integer(),
             discoveries_already_queued: non_neg_integer(),
             imports_enqueued: non_neg_integer(),
             imports_already_queued: non_neg_integer(),
             failed: non_neg_integer(),
             dry_run: boolean()
           }}
  def run(opts \\ []) when is_list(opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    events = Events.list_active_events()

    {discoveries, disc_already, discovery_failed} = trigger_discoveries(events, dry_run?)
    {imports, imp_already, import_failed} = trigger_imports(events, dry_run?)
    failed = discovery_failed + import_failed

    Logger.info(
      "SyncFestivals: events=#{length(events)} discoveries=#{discoveries} " <>
        "disc_already=#{disc_already} imports=#{imports} imp_already=#{imp_already} " <>
        "failed=#{failed}" <> if(dry_run?, do: " [dry-run]", else: "")
    )

    {:ok,
     %{
       events: length(events),
       discoveries_enqueued: discoveries,
       discoveries_already_queued: disc_already,
       imports_enqueued: imports,
       imports_already_queued: imp_already,
       failed: failed,
       dry_run: dry_run?
     }}
  end

  # ===== private =====

  defp trigger_discoveries(_events, true), do: {0, 0, 0}

  defp trigger_discoveries(events, false) do
    Enum.reduce(events, {0, 0, 0}, fn event, {ok, already, err} ->
      imdb_id =
        event.imdb_event_id || get_in(event.source_config || %{}, ["imdb_event_id"])

      if is_nil(imdb_id) do
        Logger.debug(
          "SyncFestivals: skipping discovery for #{event.source_key} " <>
            "(event_id=#{event.id}, missing imdb_event_id)"
        )

        {ok, already, err}
      else
        case YearDiscoveryWorker.queue_discovery(event.source_key) do
          # Fresh insert.
          {:ok, %Oban.Job{conflict?: false}} ->
            {ok + 1, already, err}

          # Uniqueness collision — Oban returned the *existing* job; we did
          # not enqueue a new one. Tracked separately from failures so that
          # repeated runs within the unique-window report
          # `discoveries=0 already=15` rather than misleadingly counting them
          # as fresh enqueues.
          {:ok, %Oban.Job{conflict?: true}} ->
            {ok, already + 1, err}

          # Old/legacy form — also benign, treat as an enqueue.
          {:ok, _job} ->
            {ok + 1, already, err}

          # Genuine errors (changeset validation, etc.).
          {:error, %Ecto.Changeset{}} ->
            {ok, already + 1, err}

          {:error, reason} ->
            Logger.warning(
              "SyncFestivals: discovery enqueue failed for #{event.source_key}: #{inspect(reason)}"
            )

            {ok, already, err + 1}
        end
      end
    end)
  end

  defp trigger_imports(events, dry_run?) do
    pairs = imports_to_run(events)

    if dry_run? do
      {length(pairs), 0, 0}
    else
      enqueue_imports(pairs)
    end
  end

  defp imports_to_run(events) do
    Enum.flat_map(events, fn event ->
      discovered = event.discovered_years || []
      existing = existing_ceremony_years(event)
      missing = discovered -- existing

      Enum.map(missing, fn year -> {event.source_key, year} end)
    end)
  end

  # FestivalEvent has no FK to FestivalOrganization — they're linked by
  # `abbreviation` string. Match via SQL join; missing/nil abbreviation
  # naturally returns no rows.
  defp existing_ceremony_years(event) do
    Repo.replica().all(
      from c in "festival_ceremonies",
        join: o in "festival_organizations",
        on: c.organization_id == o.id,
        where: o.abbreviation == ^event.abbreviation,
        select: c.year,
        distinct: true
    )
  end

  defp enqueue_imports(pairs) do
    Enum.reduce(pairs, {0, 0, 0}, fn {source_key, year}, {ok, already, err} ->
      case Cultural.import_festival_year(source_key, year) do
        {:ok, %{status: :already_queued}} ->
          {ok, already + 1, err}

        {:ok, _} ->
          {ok + 1, already, err}

        {:error, reason} ->
          Logger.warning(
            "SyncFestivals: import enqueue failed for #{source_key}/#{year}: #{inspect(reason)}"
          )

          {ok, already, err + 1}
      end
    end)
  end
end
