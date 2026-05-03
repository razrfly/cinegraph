defmodule Mix.Tasks.Cinegraph.Audit.ImdbListIntegrity do
  @moduledoc """
  Audit stored IMDb canonical list memberships without fetching IMDb.

  ## Usage

      mix cinegraph.audit.imdb_list_integrity
      mix cinegraph.audit.imdb_list_integrity --json
  """
  use Mix.Task

  alias Cinegraph.Health.ImdbListIntegrityAudit

  @shortdoc "Audit stored IMDb list membership integrity"

  @doc false
  @impl Mix.Task
  def run(args) do
    {opts, positional_args, invalid} = parse_args(args)
    raise_invalid_options!(invalid)
    raise_unexpected_args!(positional_args)

    Mix.Task.run("app.start")

    result = ImdbListIntegrityAudit.audit()

    if Keyword.get(opts, :json, false) do
      result |> Jason.encode!(pretty: true) |> IO.puts()
    else
      print_table(result)
    end
  end

  @doc false
  def parse_args(args) do
    OptionParser.parse(args, strict: [json: :boolean])
  end

  defp print_table(%{
         generated_at: at,
         summary: summary,
         lists: lists,
         recommended_commands: commands
       }) do
    Mix.shell().info("IMDb list integrity audit - generated #{at}")

    Mix.shell().info(
      "active=#{summary.total_active_imdb} complete=#{summary.complete} partial=#{summary.partial} discontinuous=#{summary.discontinuous} blank=#{summary.blank} missing_expected=#{summary.missing_expected_count}"
    )

    Mix.shell().info("")

    Mix.shell().info(
      String.pad_trailing("source_key", 32) <>
        String.pad_leading("count", 7) <>
        String.pad_leading("expect", 8) <>
        String.pad_leading("min", 7) <>
        String.pad_leading("max", 7) <>
        String.pad_leading("miss", 7) <>
        String.pad_leading("dupe", 7) <>
        String.pad_leading("unrank", 8) <>
        "  status"
    )

    Mix.shell().info(String.duplicate("-", 100))

    Enum.each(lists, fn list ->
      Mix.shell().info(
        String.pad_trailing(list.source_key, 32) <>
          String.pad_leading(to_string(list.stored_movie_count), 7) <>
          String.pad_leading(to_string(list.expected_movie_count || "-"), 8) <>
          String.pad_leading(to_string(list.min_position || "-"), 7) <>
          String.pad_leading(to_string(list.max_position || "-"), 7) <>
          String.pad_leading(to_string(list.missing_position_count), 7) <>
          String.pad_leading(to_string(length(list.duplicate_positions)), 7) <>
          String.pad_leading(to_string(list.unranked_count), 8) <>
          "  " <>
          list.status
      )
    end)

    if commands != [] do
      Mix.shell().info("")
      Mix.shell().info("recommended commands:")
      Enum.each(commands, &Mix.shell().info("  #{&1}"))
    end
  end

  defp raise_invalid_options!([]), do: :ok
  defp raise_invalid_options!(invalid), do: Mix.raise("invalid option(s): #{inspect(invalid)}")

  defp raise_unexpected_args!([]), do: :ok
  defp raise_unexpected_args!(args), do: Mix.raise("unexpected argument(s): #{inspect(args)}")
end
