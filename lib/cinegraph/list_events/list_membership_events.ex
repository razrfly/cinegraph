defmodule Cinegraph.ListEvents.ListMembershipEvents do
  @moduledoc """
  Context for addition/removal events against canonical list editions (#1115).

  Stores the ground truth — *when* a film was added to or removed from a list
  edition — that the prediction product needs but the DB previously lacked (it
  held only current-union membership in `movies.canonical_sources`).

  Events are append-only facts. The bulk hot path is `upsert_events/1`, which is
  idempotent via the two partial unique indexes (matched rows on the issue's
  `(source_key, movie_id, event_type, event_edition)` key; pending rows on raw
  scrape identity). Unmatched scrapes are kept as `pending` rows — never dropped.
  """

  import Ecto.Query

  alias Cinegraph.ListEvents.ListMembershipEvent
  alias Cinegraph.Movies
  alias Cinegraph.Repo

  @replace_on_conflict [:event_date, :source_url, :provenance, :updated_at]

  @doc """
  Insert a single event from attrs (changeset path — tests / one-offs).
  """
  def create_event(attrs) do
    %ListMembershipEvent{}
    |> ListMembershipEvent.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Bulk idempotent upsert. Accepts a list of attr maps (string- or atom-keyed are
  normalized to the schema fields). Rows are split into matched (movie_id present)
  and pending (movie_id nil) and inserted with the matching partial-index conflict
  target; `on_conflict` replaces the enrichable fields so a later scrape can fill
  in `event_date`/`provenance` without creating a duplicate.

  Returns `%{inserted: n, matched: n, pending: n}` where `inserted` counts rows
  actually written (conflicts that no-op are not double-counted).
  """
  def upsert_events(rows) when is_list(rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    prepared = Enum.map(rows, &prepare_row(&1, now))

    {matched, pending} = Enum.split_with(prepared, &(&1.match_state == "matched"))

    # Dedup within the batch on the same key the conflict target uses — Postgres
    # rejects an ON CONFLICT statement that would touch one row twice, and a single
    # scrape can legitimately list the same film twice.
    matched = Enum.uniq_by(matched, &matched_key/1)
    pending = Enum.uniq_by(pending, &pending_key/1)

    # Partial unique indexes require the index predicate in the conflict target, so
    # an unsafe_fragment is used (a column list cannot infer a partial index). The
    # pending fragment must mirror the COALESCE expression from the migration.
    matched_inserted =
      insert_chunk(
        matched,
        {:unsafe_fragment,
         "(source_key, movie_id, event_type, event_edition) WHERE movie_id IS NOT NULL"}
      )

    pending_inserted =
      insert_chunk(
        pending,
        {:unsafe_fragment,
         "(source_key, event_type, event_edition, coalesce(raw_imdb_id, ''), " <>
           "coalesce(raw_title, ''), coalesce(raw_year, 0)) WHERE movie_id IS NULL"}
      )

    %{
      inserted: matched_inserted + pending_inserted,
      matched: length(matched),
      pending: length(pending)
    }
  end

  defp matched_key(r), do: {r.source_key, r.movie_id, r.event_type, r.event_edition}

  defp pending_key(r),
    do:
      {r.source_key, r.event_type, r.event_edition, r.raw_imdb_id || "", r.raw_title || "",
       r.raw_year || 0}

  defp insert_chunk([], _conflict_target), do: 0

  defp insert_chunk(rows, conflict_target) do
    {count, _} =
      Repo.insert_all(ListMembershipEvent, rows,
        on_conflict: {:replace, @replace_on_conflict},
        conflict_target: conflict_target
      )

    count
  end

  # Normalizes one input map into a fully-populated insert_all row (insert_all does
  # no casting or defaulting — every column must be present, timestamps included).
  defp prepare_row(attrs, now) do
    get = fn key -> Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) end
    movie_id = get.(:movie_id)
    match_state = get.(:match_state) || if(movie_id, do: "matched", else: "pending")

    %{
      source_key: get.(:source_key),
      movie_id: movie_id,
      event_type: to_string_or_nil(get.(:event_type)),
      event_edition: to_string_or_nil(get.(:event_edition)),
      event_date: get.(:event_date),
      match_state: match_state,
      raw_title: get.(:raw_title),
      raw_year: get.(:raw_year),
      raw_imdb_id: get.(:raw_imdb_id),
      source_url: get.(:source_url),
      provenance: get.(:provenance) || %{},
      inserted_at: now,
      updated_at: now
    }
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(v) when is_atom(v), do: Atom.to_string(v)
  defp to_string_or_nil(v), do: v

  @doc """
  Promote a pending row to matched once a movie has been resolved for it.
  """
  def promote_pending(event_id, movie_id) do
    case Repo.get(ListMembershipEvent, event_id) do
      nil ->
        {:error, :not_found}

      event ->
        event
        |> ListMembershipEvent.changeset(%{movie_id: movie_id, match_state: "matched"})
        |> Repo.update()
    end
  end

  @doc """
  List pending rows (optionally for a single source) for a re-match sweep.
  """
  def list_pending(source_key \\ nil) do
    query =
      from e in ListMembershipEvent,
        where: e.match_state == "pending",
        order_by: e.id

    query =
      if source_key, do: where(query, [e], e.source_key == ^source_key), else: query

    Repo.all(query)
  end

  @doc """
  Coverage stats for one list — drives the acceptance-gate table.

  Returns counts of found/matched/pending events, adds/removes (and their matched
  subsets), and the edition span observed.
  """
  def coverage_for(source_key) do
    rows =
      Repo.all(
        from e in ListMembershipEvent,
          where: e.source_key == ^source_key,
          group_by: [e.event_type, e.match_state],
          select: {e.event_type, e.match_state, count(e.id)}
      )

    editions =
      Repo.all(
        from e in ListMembershipEvent,
          where: e.source_key == ^source_key,
          distinct: true,
          select: e.event_edition
      )
      |> Enum.sort()

    tally = fn type, state ->
      rows
      |> Enum.filter(fn {t, s, _} -> matches?(t, type) and matches?(s, state) end)
      |> Enum.reduce(0, fn {_, _, c}, acc -> acc + c end)
    end

    %{
      source_key: source_key,
      found: tally.(:any, :any),
      matched: tally.(:any, "matched"),
      pending: tally.(:any, "pending"),
      adds: tally.("added", :any),
      removes: tally.("removed", :any),
      adds_matched: tally.("added", "matched"),
      removes_matched: tally.("removed", "matched"),
      editions: editions,
      min_edition: List.first(editions),
      max_edition: List.last(editions)
    }
  end

  defp matches?(_value, :any), do: true
  defp matches?(value, target), do: value == target

  @doc """
  Coverage for every source_key present in the table.
  """
  def coverage_all do
    Repo.all(
      from e in ListMembershipEvent, distinct: true, select: e.source_key, order_by: e.source_key
    )
    |> Enum.map(&coverage_for/1)
  end

  @doc """
  Reconcile matched add/remove events against current canonical membership.

  `net_adds` = matched adds − matched removes. `current_members` comes from
  `Movies.count_canonical_movies/1`. A non-zero `discrepancy` is surfaced (listed,
  not hidden) — it is expected for lists whose membership predates our event
  coverage or whose current-union count includes unmatched films.
  """
  def reconcile(source_key) do
    cov = coverage_for(source_key)
    net_adds = cov.adds_matched - cov.removes_matched
    current = Movies.count_canonical_movies(source_key)

    %{
      source_key: source_key,
      net_adds: net_adds,
      current_members: current,
      discrepancy: net_adds - current,
      reconciled?: net_adds == current
    }
  end
end
