defmodule Cinegraph.Health.QueueFailures do
  @moduledoc """
  Generic discard analysis for an Oban queue and/or worker. Reads
  `oban_jobs` (via `Cinegraph.Health.ObanReader`), classifies each
  discarded job's last error into a generic pattern, and reports
  per-worker counts + per-pattern clusters with sample text.

  Pure DB; no live fetch. Reusable across queues — call with
  `[queue: "omdb"]`, `[worker: "Cinegraph.Workers.OmdbWorker"]`, or both.

  See #766 (audit pattern), #760 (the OMDb spike that motivated this
  generic version), #772 (this tool's home).
  """

  alias Cinegraph.Health.ObanReader

  @doc """
  Run the audit. Returns a JSON-encodable map.

  Required: at least one of `:queue` or `:worker` (raises otherwise).
  Options:
    * `:days` — window size in days (default: 7).
    * `:queue` — Oban queue name (string).
    * `:worker` — fully-qualified worker module string.
    * `:top_n` — how many error patterns to surface in `top_errors`
      (default: 5).

  Shape:

      %{
        generated_at: DateTime.t(),
        window_days: pos_integer(),
        filter: %{queue: String.t() | nil, worker: String.t() | nil},
        summary: %{
          total_discarded: non_neg_integer(),
          by_worker: %{worker_string => non_neg_integer()},
          by_error_pattern: %{atom() => non_neg_integer()}
        },
        top_errors: [%{
          pattern: atom(),
          count: non_neg_integer(),
          pct: float(),
          sample_error: String.t() | nil,
          sample_workers: [String.t()]
        }]
      }
  """
  def audit(opts \\ []) do
    days = Keyword.get(opts, :days, 7)
    top_n = Keyword.get(opts, :top_n, 5)
    queue = Keyword.get(opts, :queue)
    worker = Keyword.get(opts, :worker)

    validate_positive_integer!(:days, days)
    validate_positive_integer!(:top_n, top_n)

    if is_nil(queue) and is_nil(worker) do
      raise ArgumentError, "audit/1 requires :queue or :worker"
    end

    start_dt =
      DateTime.utc_now()
      |> DateTime.add(-days * 86_400, :second)
      |> DateTime.truncate(:second)

    rows =
      ObanReader.discards_for_queue(
        Enum.reject([queue: queue, worker: worker], fn {_k, v} -> is_nil(v) end),
        start_dt
      )

    classified = Enum.map(rows, &Map.put(&1, :pattern, classify_error(&1.last_error)))

    %{
      generated_at: DateTime.utc_now(),
      window_days: days,
      filter: %{queue: queue, worker: worker},
      summary: build_summary(classified),
      top_errors: build_top_errors(classified, top_n)
    }
  end

  @doc """
  Classify an Oban error string into a generic pattern label.

  ## Examples

      iex> Cinegraph.Health.QueueFailures.classify_error(
      ...>   ~s|** (Oban.PerformError) ... failed with {:error, "HTTP 429 Too Many Requests"}|
      ...> )
      :rate_limit

      iex> Cinegraph.Health.QueueFailures.classify_error(
      ...>   ~s|** (Oban.PerformError) ... failed with {:error, {:rate_limit, 60}}|
      ...> )
      :rate_limit

      iex> Cinegraph.Health.QueueFailures.classify_error(
      ...>   ~s|** (Oban.PerformError) ... failed with {:error, "HTTP 403 Forbidden"}|
      ...> )
      :http_4xx

      iex> Cinegraph.Health.QueueFailures.classify_error(
      ...>   ~s|** (Oban.PerformError) ... failed with {:error, "HTTP 502 Bad Gateway"}|
      ...> )
      :http_5xx

      iex> Cinegraph.Health.QueueFailures.classify_error(
      ...>   ~s|** (Oban.PerformError) ... failed with {:error, :timeout}|
      ...> )
      :network

      iex> Cinegraph.Health.QueueFailures.classify_error(
      ...>   ~s|** (Oban.PerformError) ... failed with {:error, {:crawlbase_error, 520, "HTTP 520"}}|
      ...> )
      :crawlbase

      iex> Cinegraph.Health.QueueFailures.classify_error(
      ...>   ~s|** (Oban.CancelError) ... cancelled with "no_tmdb_match — Foo (tt12345)"|
      ...> )
      :no_tmdb_match

      iex> Cinegraph.Health.QueueFailures.classify_error(
      ...>   ~s|** (Postgrex.Error) ERROR 42P01 (undefined_table) relation "foo" does not exist|
      ...> )
      :db_error

      iex> Cinegraph.Health.QueueFailures.classify_error(
      ...>   ~s|** (Jason.DecodeError) unexpected byte at position 0: 0x3C ("<")|
      ...> )
      :json_error

      iex> Cinegraph.Health.QueueFailures.classify_error(
      ...>   ~s|** (Postgrex.Error) ERROR 23505 (unique_violation) duplicate key value violates unique constraint|
      ...> )
      :unique_violation

      iex> Cinegraph.Health.QueueFailures.classify_error(
      ...>   ~s|** (RuntimeError) something nobody anticipated|
      ...> )
      :other

      iex> Cinegraph.Health.QueueFailures.classify_error(nil)
      :no_error
  """
  def classify_error(nil), do: :no_error

  def classify_error(text) when is_binary(text) do
    cond do
      # unique_violation comes from Postgrex but is a meaningful sub-pattern,
      # so it's checked BEFORE :db_error.
      String.contains?(text, "unique_violation") ->
        :unique_violation

      # rate_limit catches both Crawlbase 429 tuples and plain 429s — checked
      # before :crawlbase and :http_4xx.
      String.contains?(text, "{:rate_limit") or
        String.contains?(text, "HTTP 429") or
          String.contains?(text, ", 429") ->
        :rate_limit

      String.contains?(text, "{:crawlbase_error") ->
        :crawlbase

      # no_tmdb_match is a custom error string from TMDbDetailsWorker (#457).
      String.contains?(text, "no_tmdb_match") or
          String.contains?(text, "not found in TMDb") ->
        :no_tmdb_match

      String.contains?(text, "** (Postgrex.Error)") ->
        :db_error

      String.contains?(text, "** (Jason.") ->
        :json_error

      String.contains?(text, "HTTP 5") ->
        :http_5xx

      String.contains?(text, "HTTP 4") ->
        :http_4xx

      String.contains?(text, ":timeout") or
        String.contains?(text, ":econnrefused") or
        String.contains?(text, ":nxdomain") or
          String.contains?(text, "{:network_error") ->
        :network

      true ->
        :other
    end
  end

  defp build_summary(classified) do
    %{
      total_discarded: length(classified),
      by_worker: Enum.frequencies_by(classified, & &1.worker),
      by_error_pattern: Enum.frequencies_by(classified, & &1.pattern)
    }
  end

  defp build_top_errors(classified, top_n) do
    total = length(classified)

    classified
    |> Enum.group_by(& &1.pattern)
    |> Enum.map(fn {pattern, rows} ->
      rows = Enum.sort_by(rows, &row_sort_key/1)

      sample_workers =
        rows
        |> Enum.map(& &1.worker)
        |> Enum.uniq()
        |> Enum.take(3)

      sample_error = rows |> List.first() |> Map.get(:last_error)

      %{
        pattern: pattern,
        count: length(rows),
        pct: pct(length(rows), total),
        sample_error: sample_error,
        sample_workers: sample_workers
      }
    end)
    |> Enum.sort_by(fn r -> {-r.count, r.pattern} end)
    |> Enum.take(top_n)
  end

  defp validate_positive_integer!(_name, value) when is_integer(value) and value > 0, do: :ok

  defp validate_positive_integer!(name, value) do
    raise ArgumentError, "#{inspect(name)} must be a positive integer, got: #{inspect(value)}"
  end

  defp row_sort_key(row) do
    discarded_at =
      case Map.get(row, :discarded_at) do
        %DateTime{} = dt -> DateTime.to_unix(dt, :microsecond)
        _ -> 0
      end

    {discarded_at, Map.get(row, :id, 0), Map.get(row, :worker), Map.get(row, :last_error)}
  end

  defp pct(_, 0), do: 0.0
  defp pct(n, total), do: Float.round(n / total * 100, 2)
end
