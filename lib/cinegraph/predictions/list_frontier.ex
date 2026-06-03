defmodule Cinegraph.Predictions.ListFrontier do
  @moduledoc """
  Resolve a list's **prediction cutoff** — the release year at/after which an off-list film is a
  genuine "next-edition" candidate rather than one the editors already passed over for years
  (#1036 / #1038).

  A canon list (e.g. *1001 Movies You Must See Before You Die*) is refreshed in editions: the
  next edition adds *recent* films. So a 1998 film not on the list isn't "about to be added" —
  it was eligible across many editions and rejected. Only films from the list's frontier forward
  are real predictions.

  Cutoff source, in priority order:
    1. an explicit edition/published year in the list's `metadata` (e.g. `%{"edition" => "2024"}`)
    2. else the **newest member's release year** (works for any list, even with no edition field)

  Also reports freshness (`last_import_at`) and warnings (stale import, edition/data disagreement,
  or no usable cutoff) so callers don't silently gate against an outdated frontier.
  """

  import Ecto.Query

  alias Cinegraph.Movies.{Movie, MovieList}
  alias Cinegraph.Repo

  # Canon lists are refreshed in ~yearly editions, so an import within a year is "fresh enough";
  # beyond that a new edition may exist and the cutoff could be stale.
  @fresh_days 365
  @disagree_years 2

  @doc """
  Returns a frontier report for `source_key`:

      %{
        source_key:, cutoff_year:, cutoff_source: :edition | :newest_member | :none,
        edition_year:, newest_member_year:, newest_member_title:,
        last_import_at:, fresh?:, warnings: [String.t()]
      }
  """
  def resolve(source_key) when is_binary(source_key) do
    list = Repo.get_by(MovieList, source_key: source_key)
    edition_year = list && edition_year(list.metadata)
    {newest_year, newest_title} = newest_member(source_key)
    last_import = list && list.last_import_at
    fresh? = fresh?(last_import)

    {cutoff_year, cutoff_source} =
      cond do
        is_integer(edition_year) -> {edition_year, :edition}
        is_integer(newest_year) -> {newest_year, :newest_member}
        true -> {nil, :none}
      end

    %{
      source_key: source_key,
      cutoff_year: cutoff_year,
      cutoff_source: cutoff_source,
      edition_year: edition_year,
      newest_member_year: newest_year,
      newest_member_title: newest_title,
      last_import_at: last_import,
      fresh?: fresh?,
      warnings: warnings(edition_year, newest_year, fresh?, last_import, cutoff_source)
    }
  end

  # ── internals ────────────────────────────────────────────────────────────────

  defp edition_year(nil), do: nil

  defp edition_year(meta) when is_map(meta) do
    ~w(edition published_year year)
    |> Enum.find_value(fn k -> parse_year(meta[k]) end)
  end

  defp edition_year(_), do: nil

  defp parse_year(y) when is_integer(y) and y > 1800 and y < 2200, do: y

  defp parse_year(y) when is_binary(y) do
    case Integer.parse(y) do
      {n, _} when n > 1800 and n < 2200 -> n
      _ -> nil
    end
  end

  defp parse_year(_), do: nil

  defp newest_member(source_key) do
    row =
      Repo.one(
        from m in Movie,
          where: fragment("? \\? ?", m.canonical_sources, ^source_key),
          where: not is_nil(m.release_date),
          order_by: [desc: m.release_date],
          limit: 1,
          select: {m.release_date, m.title}
      )

    case row do
      {%Date{year: y}, title} -> {y, title}
      _ -> {nil, nil}
    end
  end

  defp fresh?(nil), do: false

  defp fresh?(%NaiveDateTime{} = dt),
    do: Date.diff(Date.utc_today(), NaiveDateTime.to_date(dt)) <= @fresh_days

  defp fresh?(%DateTime{} = dt),
    do: Date.diff(Date.utc_today(), DateTime.to_date(dt)) <= @fresh_days

  defp warnings(edition_year, newest_year, fresh?, last_import, cutoff_source) do
    []
    |> add_if(
      is_integer(edition_year) and is_integer(newest_year) and
        abs(edition_year - newest_year) >= @disagree_years,
      "edition year #{edition_year} disagrees with newest member year #{newest_year} — possible stale import or data issue"
    )
    |> add_if(
      not fresh?,
      "list last imported #{import_label(last_import)}; frontier may be stale (re-import to refresh the cutoff)"
    )
    |> add_if(
      cutoff_source == :none,
      "no edition metadata and no dated members — recency gate disabled (showing all eras)"
    )
    |> Enum.reverse()
  end

  defp add_if(list, true, msg), do: [msg | list]
  defp add_if(list, false, _msg), do: list

  defp import_label(nil), do: "never"
  defp import_label(dt), do: to_string(dt)
end
