defmodule Mix.Tasks.Festivals.Backfill do
  use Mix.Task

  @shortdoc "Backfill festival nominations for BAFTA, CCA, or all seeded festivals"

  @moduledoc """
  Queue UnifiedFestivalWorker jobs to backfill nomination data for festivals
  that have seeds but no imported data.

  ## Usage

      mix festivals.backfill
      mix festivals.backfill --festival bafta
      mix festivals.backfill --festival critics_choice
      mix festivals.backfill --years 1990-2024
      mix festivals.backfill --all

  ## Options

    * `--festival` - Import a single festival by source_key (e.g. "bafta")
    * `--years` - Year range to backfill (format: START-END, default: 2000-2024)
    * `--all` - Backfill all active seeded festivals (excluding oscars)
    * `--dry-run` - Show what would be queued without making changes

  ## Examples

      # Backfill BAFTA and CCA for 2000-2024 (default)
      mix festivals.backfill

      # Backfill BAFTA only
      mix festivals.backfill --festival bafta

      # Backfill all festivals for a custom range
      mix festivals.backfill --all --years 1990-2024

      # Dry run
      mix festivals.backfill --dry-run

  """

  @default_festivals ["bafta", "critics_choice"]
  @default_start_year 2000
  @default_end_year 2024

  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          festival: :string,
          years: :string,
          all: :boolean,
          dry_run: :boolean
        ]
      )

    dry_run = opts[:dry_run] || false

    {start_year, end_year} =
      case opts[:years] do
        nil ->
          {@default_start_year, @default_end_year}

        range_str ->
          case parse_year_range(range_str) do
            {:ok, s, e} ->
              {s, e}

            :error ->
              Mix.shell().error("Invalid year range format. Use: START-END (e.g., 2000-2024)")
              exit(:normal)
          end
      end

    festivals =
      cond do
        opts[:festival] ->
          [opts[:festival]]

        opts[:all] ->
          Cinegraph.Events.list_active_events()
          |> Enum.map(& &1.source_key)
          |> Enum.reject(&(&1 == "oscars"))

        true ->
          @default_festivals
      end

    if festivals == [] do
      Mix.shell().error("No festivals found to backfill.")
      exit(:normal)
    end

    Mix.shell().info(
      "#{if dry_run, do: "[DRY RUN] ", else: ""}Backfilling #{length(festivals)} festival(s) for #{start_year}-#{end_year}..."
    )

    Mix.shell().info("Festivals: #{Enum.join(festivals, ", ")}\n")

    {queued, failed} =
      Enum.reduce(festivals, {0, 0}, fn festival_key, {q, f} ->
        {q2, f2} = backfill_festival(festival_key, start_year..end_year, dry_run)
        {q + q2, f + f2}
      end)

    Mix.shell().info("\n📊 Backfill Summary:")
    Mix.shell().info("  • Total queued: #{queued}")
    Mix.shell().info("  • Total failed: #{failed}")

    unless dry_run do
      Mix.shell().info("\nMonitor progress at: http://localhost:4001/dev/oban")
    end
  end

  defp backfill_festival(festival_key, year_range, dry_run) do
    label = String.upcase(festival_key)

    Enum.reduce(year_range, {0, 0}, fn year, {q, f} ->
      if dry_run do
        Mix.shell().info("  • Would queue #{label} #{year}")
        {q + 1, f}
      else
        case Cinegraph.Cultural.import_festival_year(festival_key, year) do
          {:ok, %{status: :already_queued}} ->
            Mix.shell().info("  ⏭️  Already queued #{label} #{year}")
            {q, f}

          {:ok, _} ->
            Mix.shell().info("  ✅ Queued #{label} #{year}")
            {q + 1, f}

          {:error, reason} ->
            Mix.shell().error("  ❌ #{label} #{year} failed: #{inspect(reason)}")
            {q, f + 1}
        end
      end
    end)
  end

  defp parse_year_range(range_str) do
    case String.split(range_str, "-") do
      [start_str, end_str] ->
        with {start_year, ""} <- Integer.parse(start_str),
             {end_year, ""} <- Integer.parse(end_str),
             true <- start_year <= end_year do
          {:ok, start_year, end_year}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end
end
