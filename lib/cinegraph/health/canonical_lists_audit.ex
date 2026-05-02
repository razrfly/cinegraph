defmodule Cinegraph.Health.CanonicalListsAudit do
  @moduledoc """
  Audits database-managed canonical movie lists, especially IMDb `ls...`
  lists that are configured but have no movies attached in `canonical_sources`.
  """

  import Ecto.Query

  alias Cinegraph.Movies.{Movie, MovieList}
  alias Cinegraph.Repo

  @default_stale_days 90

  @doc """
  Return a JSON-safe audit of active canonical movie lists.

  Options:
    * `:blank_only` - only include blank active IMDb lists
    * `:stale_days` - threshold for stale/pending flags, default 90
  """
  def audit(opts \\ []) do
    stale_days = stale_days!(opts)
    blank_only? = Keyword.get(opts, :blank_only, false)

    rows =
      list_rows()
      |> Enum.map(&decorate_row(&1, stale_days))
      |> maybe_filter_blank(blank_only?)

    candidates = Enum.filter(rows, & &1.refresh_candidate)

    %{
      generated_at: DateTime.utc_now(),
      stale_days: stale_days,
      summary: %{
        total_active: length(rows),
        active_imdb: Enum.count(rows, &(&1.source_type == "imdb")),
        refresh_candidates: length(candidates),
        blank: Enum.count(rows, & &1.blank),
        never_imported: Enum.count(rows, & &1.never_imported),
        stale: Enum.count(rows, & &1.stale),
        pending_too_long: Enum.count(rows, & &1.pending_too_long),
        below_expected: Enum.count(rows, & &1.below_expected)
      },
      lists: rows,
      recommended_commands: recommended_commands(candidates, stale_days)
    }
  end

  defp stale_days!(opts) do
    case Keyword.get(opts, :stale_days, @default_stale_days) do
      n when is_integer(n) and n > 0 ->
        n

      other ->
        raise ArgumentError, ":stale_days must be a positive integer, got: #{inspect(other)}"
    end
  end

  defp list_rows do
    MovieList
    |> where([ml], ml.active == true)
    |> join(:left, [ml], m in Movie, on: fragment("? \\? ?", m.canonical_sources, ml.source_key))
    |> group_by([ml], ml.id)
    |> order_by([ml], asc: ml.source_key)
    |> select([ml, m], %{list: ml, movie_count: count(m.id)})
    |> Repo.replica().all()
  end

  defp decorate_row(%{list: %MovieList{} = list, movie_count: movie_count}, stale_days) do
    expected = expected_movie_count(list.metadata || %{})
    blank? = movie_count == 0
    never_imported? = is_nil(list.last_import_at)
    stale? = stale?(list.last_import_at, stale_days)
    pending_too_long? = list.last_import_status == "pending" and stale?
    below_expected? = is_integer(expected) and movie_count < expected
    imdb? = list.source_type == "imdb"

    %{
      source_key: list.source_key,
      name: list.name,
      source_type: list.source_type,
      source_id: list.source_id,
      source_url: list.source_url,
      movie_count: movie_count,
      expected_movie_count: expected,
      last_import_at: list.last_import_at,
      last_import_status: list.last_import_status,
      total_imports: list.total_imports || 0,
      blank: blank?,
      never_imported: never_imported?,
      stale: stale?,
      pending_too_long: pending_too_long?,
      below_expected: below_expected?,
      refresh_candidate:
        imdb? and (blank? or never_imported? or stale? or pending_too_long? or below_expected?)
    }
  end

  defp expected_movie_count(%{} = metadata) do
    case metadata["expected_movie_count"] do
      n when is_integer(n) -> n
      n when is_binary(n) -> parse_positive_integer(n)
      _ -> nil
    end
  end

  defp parse_positive_integer(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp stale?(nil, _stale_days), do: false

  defp stale?(%NaiveDateTime{} = dt, stale_days) do
    dt
    |> DateTime.from_naive!("Etc/UTC")
    |> stale?(stale_days)
  end

  defp stale?(%DateTime{} = dt, stale_days) do
    DateTime.diff(DateTime.utc_now(), dt, :day) >= stale_days
  end

  defp maybe_filter_blank(rows, true),
    do: Enum.filter(rows, &(&1.source_type == "imdb" and &1.blank))

  defp maybe_filter_blank(rows, false), do: rows

  defp recommended_commands([], _stale_days), do: []

  defp recommended_commands(_candidates, stale_days) do
    [
      "mix cinegraph.canonical.enqueue_refresh --blank-only --limit 10",
      "mix cinegraph.canonical.enqueue_refresh --stale-days #{stale_days} --limit 10",
      "mix cinegraph.prod.canonical.enqueue_refresh --blank-only --limit 10"
    ]
  end
end
