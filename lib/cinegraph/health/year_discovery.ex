defmodule Cinegraph.Health.YearDiscovery do
  @moduledoc """
  Audit `Cinegraph.Workers.YearDiscoveryWorker` health per festival.

  Reads `oban_jobs` (via `Cinegraph.Health.ObanReader`), classifies the
  most recent error per festival into one of a fixed set of labels, and
  joins against active `FestivalEvent` rows to produce a per-festival
  report.

  Pure DB; no live IMDb / Crawlbase fetch — that path is reserved for a
  separate live-event-id inspector tool. Audits must be fast and
  side-effect-free.

  See #759 (the immediate consumer) and #766 (the tooling pattern).
  """

  alias Cinegraph.Events
  alias Cinegraph.Events.FestivalEvent
  alias Cinegraph.Health.ObanReader

  @worker "Cinegraph.Workers.YearDiscoveryWorker"

  @doc """
  Run the audit. Returns a JSON-encodable map.

  Options:
    * `:days` — window size in days (default: 7).

  Shape:

      %{
        generated_at: DateTime.t(),
        window_days: pos_integer(),
        summary: %{
          total_active_with_event_id: non_neg_integer(),
          completed: non_neg_integer(),
          discarded: non_neg_integer(),
          retryable: non_neg_integer(),
          no_runs: non_neg_integer(),
          by_label: %{atom() => non_neg_integer()}
        },
        festivals: [%{
          source_key: String.t(),
          name: String.t(),
          imdb_event_id: String.t(),
          discarded: non_neg_integer(),
          completed: non_neg_integer(),
          retryable: non_neg_integer(),
          last_error: String.t() | nil,
          label: atom(),
          attempts_used: non_neg_integer(),
          last_failure_at: DateTime.t() | nil,
          years_discovered_at: DateTime.t() | nil,
          discovered_years_count: non_neg_integer(),
          max_available_year: integer() | nil
        }]
      }
  """
  def audit(opts \\ []) do
    days = Keyword.get(opts, :days, 7)

    start_dt =
      DateTime.utc_now()
      |> DateTime.add(-days * 86_400, :second)
      |> DateTime.truncate(:second)

    job_summary = ObanReader.jobs_summary_for_worker(@worker, start_dt)

    festivals =
      Events.list_active_events()
      |> Enum.flat_map(&with_event_id/1)
      |> Enum.map(&build_festival_row(&1, job_summary))
      |> Enum.sort_by(&{&1.label, &1.source_key})

    %{
      generated_at: DateTime.utc_now(),
      window_days: days,
      summary: build_summary(festivals),
      festivals: festivals
    }
  end

  @doc """
  Classify an Oban error string into an audit label.

  The error column in `oban_jobs.errors[].error` is the result of
  `Exception.format/2` — i.e. the *inspected* string, not a raw tuple —
  so classification is by `String.contains?/2` against known fragments.

  Order matters: `rate_limit` must be checked before `crawlbase_error`
  because 429s can appear inside `{:crawlbase_error, ...}` tuples.

  ## Examples

      iex> Cinegraph.Health.YearDiscovery.classify_error(
      ...>   ~s|** (Oban.PerformError) ... failed with {:error, "No years found in historyEventEditions"}|
      ...> )
      :source_unavailable

      iex> Cinegraph.Health.YearDiscovery.classify_error(
      ...>   ~s|** (Oban.PerformError) ... failed with {:error, "No __NEXT_DATA__ found"}|
      ...> )
      :parser_breakage

      iex> Cinegraph.Health.YearDiscovery.classify_error(
      ...>   ~s|** (Oban.PerformError) ... failed with {:error, "JSON parsing failed"}|
      ...> )
      :parser_breakage

      iex> Cinegraph.Health.YearDiscovery.classify_error(
      ...>   ~s|** (Oban.PerformError) ... failed with {:error, {:rate_limit, 60}}|
      ...> )
      :rate_limit

      iex> Cinegraph.Health.YearDiscovery.classify_error(
      ...>   ~s|** (Oban.PerformError) ... failed with {:error, {:crawlbase_error, 520, "HTTP 520"}}|
      ...> )
      :crawlbase_error

      iex> Cinegraph.Health.YearDiscovery.classify_error(
      ...>   ~s|** (Oban.PerformError) ... failed with {:error, "HTTP 404"}|
      ...> )
      :bad_event_id

      iex> Cinegraph.Health.YearDiscovery.classify_error(
      ...>   ~s|** (Oban.PerformError) ... failed with {:error, :timeout}|
      ...> )
      :flaky_network

      iex> Cinegraph.Health.YearDiscovery.classify_error(
      ...>   ~s|** (Oban.PerformError) ... failed with {:error, "HTTP 502"}|
      ...> )
      :flaky_network

      iex> Cinegraph.Health.YearDiscovery.classify_error(
      ...>   ~s|** (Oban.PerformError) ... failed with {:error, :no_year_with_editions}|
      ...> )
      :source_unavailable

      iex> Cinegraph.Health.YearDiscovery.classify_error(
      ...>   ~s|** (Oban.PerformError) ... failed with {:error, "something nobody anticipated"}|
      ...> )
      :other

      iex> Cinegraph.Health.YearDiscovery.classify_error(nil)
      :no_runs
  """
  def classify_error(nil), do: :no_runs

  def classify_error(text) when is_binary(text) do
    cond do
      String.contains?(text, "No years found in historyEventEditions") ->
        :source_unavailable

      # All candidate years exhausted without finding usable editions data.
      # Covers the case where individual fetch failures (e.g. Crawlbase WAF
      # block) bubble up as the aggregate :no_year_with_editions atom.
      String.contains?(text, ":no_year_with_editions") ->
        :source_unavailable

      String.contains?(text, "No __NEXT_DATA__ found") ->
        :parser_breakage

      String.contains?(text, "JSON parsing failed") ->
        :parser_breakage

      String.contains?(text, "{:rate_limit") or String.contains?(text, ", 429") ->
        :rate_limit

      String.contains?(text, "{:crawlbase_error, 5") ->
        :crawlbase_error

      String.contains?(text, "HTTP 404") or String.contains?(text, ", 404") ->
        :bad_event_id

      String.contains?(text, ":timeout") or
        String.contains?(text, ":econnrefused") or
        String.contains?(text, ":nxdomain") or
        String.contains?(text, "{:network_error") or
          String.contains?(text, "HTTP 5") ->
        # Non-Crawlbase 5xx falls through here. Crawlbase 5xx is caught
        # earlier by `{:crawlbase_error, 5...` (order matters).
        :flaky_network

      true ->
        :other
    end
  end

  defp with_event_id(%FestivalEvent{} = ev) do
    case event_id(ev) do
      nil -> []
      id -> [{ev, id}]
    end
  end

  defp event_id(%FestivalEvent{imdb_event_id: id}) when is_binary(id) and id != "", do: id

  defp event_id(%FestivalEvent{source_config: %{} = cfg}) do
    cfg["event_id"] || cfg["imdb_event_id"]
  end

  defp event_id(_), do: nil

  defp build_festival_row({%FestivalEvent{} = ev, event_id}, job_summary) do
    summary =
      Map.get(job_summary, ev.source_key, %{
        discarded: 0,
        completed: 0,
        retryable: 0,
        last_error: nil,
        last_failure_at: nil,
        attempts_used: 0
      })

    label =
      cond do
        summary.discarded == 0 and summary.completed == 0 and summary.retryable == 0 ->
          :no_runs

        summary.discarded == 0 and summary.retryable == 0 and summary.last_error == nil ->
          # All non-empty runs in the window succeeded.
          :ok

        summary.discarded == 0 and summary.retryable > 0 ->
          :retrying

        true ->
          classify_error(summary.last_error)
      end

    %{
      source_key: ev.source_key,
      name: ev.name,
      imdb_event_id: event_id,
      discarded: summary.discarded,
      completed: summary.completed,
      retryable: summary.retryable,
      last_error: summary.last_error,
      label: label,
      attempts_used: summary.attempts_used,
      last_failure_at: summary.last_failure_at,
      years_discovered_at: ev.years_discovered_at,
      discovered_years_count: length(ev.discovered_years || []),
      max_available_year: ev.max_available_year
    }
  end

  defp build_summary(festivals) do
    by_label =
      festivals
      |> Enum.frequencies_by(& &1.label)

    %{
      total_active_with_event_id: length(festivals),
      completed: festivals |> Enum.map(& &1.completed) |> Enum.sum(),
      discarded: festivals |> Enum.map(& &1.discarded) |> Enum.sum(),
      retryable: festivals |> Enum.map(& &1.retryable) |> Enum.sum(),
      no_runs: Map.get(by_label, :no_runs, 0),
      by_label: by_label
    }
  end
end
