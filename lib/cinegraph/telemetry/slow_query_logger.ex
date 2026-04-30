defmodule Cinegraph.Telemetry.SlowQueryLogger do
  @moduledoc """
  Logs Ecto queries that exceed a configurable wall-clock threshold (default
  500ms). Attaches to both the primary and replica repos.

  Wired up in `Cinegraph.Application.start/2` (dev only). Production already has
  PlanetScale slow-query analytics — duplicating the log there would just be noise.

  ## Output

      [warning] [SLOW QUERY 738ms] Cinegraph.Repo.Replica
        SELECT m0."id", … FROM "movies" AS m0 …
        params: [...]

  Times are reported in milliseconds (the underlying telemetry value is in
  native time units; we convert to ms once).
  """
  require Logger

  @default_threshold_ms 500

  @doc """
  Attach handlers for the primary and replica repos. Idempotent — calling twice
  is safe; existing handlers are detached first.
  """
  def attach(threshold_ms \\ @default_threshold_ms) do
    detach()

    :telemetry.attach_many(
      "cinegraph-slow-query-logger",
      [
        [:cinegraph, :repo, :query],
        [:cinegraph, :repo, :replica, :query]
      ],
      &__MODULE__.handle_event/4,
      %{threshold_ms: threshold_ms}
    )

    :ok
  end

  @doc "Detach the slow-query handler if attached."
  def detach do
    :telemetry.detach("cinegraph-slow-query-logger")
  end

  @doc false
  def handle_event(_event, %{total_time: total_time} = measurements, metadata, %{
        threshold_ms: threshold_ms
      }) do
    total_ms = System.convert_time_unit(total_time, :native, :millisecond)

    if total_ms >= threshold_ms do
      repo = metadata[:repo] || "Repo"
      query = metadata[:query] || "<no query>"
      params = inspect(metadata[:params] || [], limit: 5, printable_limit: 80)
      query_ms = ms(measurements[:query_time])
      decode_ms = ms(measurements[:decode_time])
      queue_ms = ms(measurements[:queue_time])
      idle_ms = ms(measurements[:idle_time])

      Logger.warning("""
      [SLOW QUERY #{total_ms}ms] #{inspect(repo)} \
      (query=#{query_ms}ms decode=#{decode_ms}ms queue=#{queue_ms}ms idle=#{idle_ms}ms)
        #{String.slice(query, 0..400)}
        params: #{params}\
      """)
    end

    :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp ms(nil), do: 0
  defp ms(t), do: System.convert_time_unit(t, :native, :millisecond)
end
