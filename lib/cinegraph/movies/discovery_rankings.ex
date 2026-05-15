defmodule Cinegraph.Movies.DiscoveryRankings do
  @moduledoc """
  Read model for the default movie discovery browse path.

  The materialized view precomputes the expensive discovery score used by the
  default `/movies` browse so the hot query can use an indexed score column
  instead of recomputing correlated metric subqueries for every candidate row.
  """

  import Ecto.Query

  alias Cinegraph.Movies.Movie
  alias Cinegraph.Movies.Query.Params
  alias Cinegraph.Repo

  @view_name "movie_discovery_rankings_mv"

  @doc """
  Returns true when params represent the no-filter default discovery browse.

  This is intentionally conservative. Any non-default filter or sort falls back
  to the generic search path so existing filtering semantics stay unchanged.
  """
  def default_browse?(%Params{} = params) do
    params.sort == "discovery_score_desc" and
      blank?(params.search) and
      params.show_unreleased == false and
      empty?(params.genres) and
      empty?(params.countries) and
      empty?(params.languages) and
      empty?(params.lists) and
      empty?(params.festivals) and
      empty?(params.people_ids) and
      empty?(params.production_company_ids) and
      is_nil(params.year) and
      is_nil(params.year_from) and
      is_nil(params.year_to) and
      is_nil(params.decade) and
      is_nil(params.runtime_min) and
      is_nil(params.runtime_max) and
      is_nil(params.rating_min) and
      is_nil(params.award_status) and
      is_nil(params.festival_id) and
      is_nil(params.award_category_id) and
      is_nil(params.award_year_from) and
      is_nil(params.award_year_to) and
      is_nil(params.rating_preset) and
      is_nil(params.discovery_preset) and
      is_nil(params.award_preset) and
      is_nil(params.people_role) and
      is_nil(params.festival_recognition_min) and
      is_nil(params.time_machine_min) and
      is_nil(params.auteurs_min) and
      is_nil(params.preset) and
      is_nil(params.disparity)
  end

  @doc """
  Lists movies for the optimized default browse path.
  """
  def list_default(%Params{} = params) do
    page = max(params.page || 1, 1)
    per_page = params.per_page || 50
    offset = (page - 1) * per_page

    movies =
      Movie
      |> join(:inner, [m], r in fragment("SELECT * FROM movie_discovery_rankings_mv"),
        on: r.movie_id == m.id
      )
      |> where([_m, r], r.import_status == "full")
      |> where([_m, r], r.is_released == true)
      |> order_by([_m, r],
        desc_nulls_last: r.default_discovery_score,
        desc_nulls_last: r.release_date,
        asc: r.movie_id
      )
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.replica().all()

    total_count = count_default()

    {:ok, {movies, meta(page, per_page, total_count)}}
  end

  @doc """
  Counts rows eligible for the default browse path directly from the read model.
  """
  def count_default do
    from(r in fragment("SELECT * FROM movie_discovery_rankings_mv"),
      where: r.import_status == "full",
      where: r.is_released == true,
      select: count()
    )
    |> Repo.replica().one()
  end

  @doc """
  Refreshes the materialized view and returns refresh metadata.

  Normal operational refreshes use `CONCURRENTLY`. If the view is not populated
  yet, PostgreSQL requires one non-concurrent refresh first; in that case this
  retries non-concurrently and reports the actual mode used.
  """
  def refresh(opts \\ []) do
    concurrently? = Keyword.get(opts, :concurrently, true)
    started_at = System.monotonic_time(:millisecond)

    mode =
      case do_refresh(concurrently?) do
        :ok ->
          if concurrently?, do: :concurrent, else: :non_concurrent

        {:retry, reason} ->
          require Logger

          Logger.warning(
            "Retrying #{@view_name} refresh without CONCURRENTLY: #{Exception.message(reason)}"
          )

          :ok = do_refresh!(false)
          :non_concurrent
      end

    duration_ms = System.monotonic_time(:millisecond) - started_at

    %{
      view: @view_name,
      mode: mode,
      row_count: count_all(),
      duration_ms: duration_ms,
      refreshed_at: DateTime.utc_now()
    }
  end

  defp do_refresh(concurrently?) do
    do_refresh!(concurrently?)
  rescue
    e in Postgrex.Error ->
      if concurrently? and retryable_concurrent_refresh_error?(e) do
        {:retry, e}
      else
        reraise e, __STACKTRACE__
      end
  end

  defp do_refresh!(true) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "REFRESH MATERIALIZED VIEW CONCURRENTLY #{@view_name}",
      [],
      timeout: :infinity
    )

    :ok
  end

  defp do_refresh!(false) do
    Ecto.Adapters.SQL.query!(Repo, "REFRESH MATERIALIZED VIEW #{@view_name}", [],
      timeout: :infinity
    )

    :ok
  end

  defp count_all do
    from(r in fragment("SELECT * FROM movie_discovery_rankings_mv"), select: count())
    |> Repo.one()
  end

  defp meta(page, per_page, total_count) do
    total_pages =
      case total_count do
        0 -> 0
        count -> ceil(count / per_page)
      end

    %Flop.Meta{
      current_offset: (page - 1) * per_page,
      current_page: page,
      page_size: per_page,
      next_offset: next_offset(page, per_page, total_pages),
      next_page: next_page(page, total_pages),
      previous_offset: previous_offset(page, per_page),
      previous_page: previous_page(page),
      total_count: total_count,
      total_pages: total_pages,
      has_next_page?: page < total_pages,
      has_previous_page?: page > 1,
      schema: Movie,
      flop: %Flop{page: page, page_size: per_page}
    }
  end

  defp next_offset(page, per_page, total_pages) when page < total_pages, do: page * per_page
  defp next_offset(_page, _per_page, _total_pages), do: nil

  defp next_page(page, total_pages) when page < total_pages, do: page + 1
  defp next_page(_page, _total_pages), do: nil

  defp previous_offset(page, per_page) when page > 1, do: max((page - 2) * per_page, 0)
  defp previous_offset(_page, _per_page), do: nil

  defp previous_page(page) when page > 1, do: page - 1
  defp previous_page(_page), do: nil

  defp retryable_concurrent_refresh_error?(%Postgrex.Error{postgres: postgres}) do
    message = postgres[:message] || ""

    String.contains?(message, "CONCURRENTLY") or
      String.contains?(message, "not populated") or
      String.contains?(message, "unique index")
  end

  defp blank?(value), do: is_nil(value) or value == ""
  defp empty?(value), do: is_nil(value) or value == []
end
