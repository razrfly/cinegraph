defmodule Mix.Tasks.Cinegraph.Audit.YearDiscovery do
  @moduledoc """
  Audit `Cinegraph.Workers.YearDiscoveryWorker` health per festival.

  Reads the local `oban_jobs` table over a window (default 7 days),
  classifies the most recent error per festival, and joins against active
  festival events with an IMDb event ID. Pure DB; no live IMDb fetch.

  ## Usage

      mix cinegraph.audit.year_discovery               # 7 days, table output
      mix cinegraph.audit.year_discovery --days 30
      mix cinegraph.audit.year_discovery --json        # JSON for piping to jq

  See `mix cinegraph.prod.audit.year_discovery` for the production variant
  and `MAINTENANCE.md` → "Audits & ad-hoc reports" for the full catalog.
  """
  use Mix.Task

  alias Cinegraph.Health.YearDiscovery

  @shortdoc "Audit YearDiscoveryWorker health per festival"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, invalid} = OptionParser.parse(args, strict: [json: :boolean, days: :integer])
    raise_invalid_options!(invalid)

    json? = Keyword.get(opts, :json, false)

    days =
      case Keyword.get(opts, :days, 7) do
        n when is_integer(n) and n > 0 -> n
        other -> Mix.raise("--days must be a positive integer, got: #{inspect(other)}")
      end

    result = YearDiscovery.audit(days: days)

    if json? do
      result
      |> Jason.encode!(pretty: true)
      |> IO.puts()
    else
      print_table(result)
    end
  end

  defp raise_invalid_options!([]), do: :ok

  defp raise_invalid_options!(invalid) do
    Mix.raise("invalid option(s): #{inspect(invalid)}")
  end

  defp print_table(%{generated_at: gen_at, window_days: days, summary: s, festivals: festivals}) do
    Mix.shell().info("YearDiscoveryWorker audit — last #{days} days, generated #{gen_at}")

    Mix.shell().info(
      "active w/ event_id=#{s.total_active_with_event_id}  " <>
        "completed=#{s.completed}  discarded=#{s.discarded}  " <>
        "retryable=#{s.retryable}  no_runs=#{s.no_runs}"
    )

    Mix.shell().info("by label: #{format_label_map(s.by_label)}")
    Mix.shell().info("")

    Mix.shell().info(
      String.pad_trailing("source_key", 18) <>
        String.pad_trailing("event_id", 12) <>
        String.pad_leading("disc", 6) <>
        String.pad_leading("ok", 6) <>
        String.pad_leading("retry", 7) <>
        "  " <>
        String.pad_trailing("label", 20) <>
        "last_error"
    )

    Mix.shell().info(String.duplicate("-", 110))

    Enum.each(festivals, fn f ->
      Mix.shell().info(
        String.pad_trailing(f.source_key, 18) <>
          String.pad_trailing(f.imdb_event_id || "-", 12) <>
          String.pad_leading(Integer.to_string(f.discarded), 6) <>
          String.pad_leading(Integer.to_string(f.completed), 6) <>
          String.pad_leading(Integer.to_string(f.retryable), 7) <>
          "  " <>
          String.pad_trailing(Atom.to_string(f.label), 20) <>
          truncate(f.last_error, 60)
      )
    end)
  end

  defp format_label_map(map) do
    map
    |> Enum.sort_by(fn {_label, count} -> -count end)
    |> Enum.map(fn {label, count} -> "#{label}=#{count}" end)
    |> Enum.join(" ")
  end

  defp truncate(nil, _), do: ""
  defp truncate(s, n) when byte_size(s) <= n, do: s
  defp truncate(s, n), do: String.slice(s, 0, n - 1) <> "…"
end
