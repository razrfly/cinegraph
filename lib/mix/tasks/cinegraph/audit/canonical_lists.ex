defmodule Mix.Tasks.Cinegraph.Audit.CanonicalLists do
  @moduledoc """
  Audit active canonical movie lists for blank, stale, and incomplete IMDb lists.

  ## Usage

      mix cinegraph.audit.canonical_lists
      mix cinegraph.audit.canonical_lists --json
      mix cinegraph.audit.canonical_lists --blank-only
      mix cinegraph.audit.canonical_lists --stale-days 90
  """
  use Mix.Task

  alias Cinegraph.Health.CanonicalListsAudit

  @shortdoc "Audit canonical IMDb list freshness and coverage"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [
          json: :boolean,
          blank_only: :boolean,
          "blank-only": :boolean,
          stale_days: :integer,
          "stale-days": :integer
        ]
      )

    raise_invalid_options!(invalid)
    audit_opts = audit_opts(opts)
    result = CanonicalListsAudit.audit(audit_opts)

    if Keyword.get(opts, :json, false) do
      result |> Jason.encode!(pretty: true) |> IO.puts()
    else
      print_table(result)
    end
  end

  @doc false
  def audit_opts(opts) do
    opts
    |> normalize_alias(:"blank-only", :blank_only)
    |> normalize_alias(:"stale-days", :stale_days)
    |> Keyword.take([:blank_only, :stale_days])
  end

  defp print_table(%{
         generated_at: at,
         stale_days: stale_days,
         summary: s,
         lists: lists,
         recommended_commands: commands
       }) do
    Mix.shell().info("Canonical lists audit — generated #{at}, stale_days=#{stale_days}")

    Mix.shell().info(
      "active=#{s.total_active} imdb=#{s.active_imdb} candidates=#{s.refresh_candidates}"
    )

    Mix.shell().info(
      "blank=#{s.blank} never=#{s.never_imported} stale=#{s.stale} pending=#{s.pending_too_long} below_expected=#{s.below_expected}"
    )

    Mix.shell().info("")

    Mix.shell().info(
      String.pad_trailing("source_key", 32) <>
        String.pad_leading("count", 8) <>
        String.pad_leading("expect", 8) <>
        "  " <>
        String.pad_trailing("status", 10) <>
        "flags"
    )

    Mix.shell().info(String.duplicate("-", 90))

    Enum.each(lists, fn list ->
      flags =
        [:blank, :never_imported, :stale, :pending_too_long, :below_expected]
        |> Enum.filter(&Map.get(list, &1))
        |> Enum.map(&Atom.to_string/1)
        |> Enum.join(",")

      Mix.shell().info(
        String.pad_trailing(list.source_key, 32) <>
          String.pad_leading(Integer.to_string(list.movie_count), 8) <>
          String.pad_leading(to_string(list.expected_movie_count || "-"), 8) <>
          "  " <>
          String.pad_trailing(list.last_import_status || "never", 10) <>
          flags
      )
    end)

    if commands != [] do
      Mix.shell().info("")
      Mix.shell().info("recommended commands:")
      Enum.each(commands, &Mix.shell().info("  #{&1}"))
    end
  end

  defp normalize_alias(opts, from, to) do
    case Keyword.pop(opts, from) do
      {nil, opts} -> opts
      {value, opts} -> Keyword.put(opts, to, value)
    end
  end

  defp raise_invalid_options!([]), do: :ok
  defp raise_invalid_options!(invalid), do: Mix.raise("invalid option(s): #{inspect(invalid)}")
end
