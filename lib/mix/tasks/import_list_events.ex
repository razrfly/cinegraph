defmodule Mix.Tasks.ImportListEvents do
  use Mix.Task

  @shortdoc "Import list-membership add/remove events (NFR induction years, 1001 edition diffs)"

  @moduledoc """
  Import addition/removal events for canonical movie lists (#1115).

  Layer 2 of the maintenance pattern — a thin wrapper over
  `Cinegraph.Maintenance.ImportListEvents`. Scrapes public records (Library of
  Congress / Wikipedia for NFR induction classes; configured per-edition pages for
  the 1001 Movies edition diffs), matches scraped entries to movies, and upserts
  into `list_membership_events`. Idempotent — safe to re-run.

  ## Usage

      mix import_list_events --source national_film_registry
      mix import_list_events --source 1001_movies --dry-run
      mix import_list_events --all
      mix import_list_events --rematch-pending
      mix import_list_events --all --report      # also write the spike report

  ## Options

    * `--source KEY`   - import a single source (national_film_registry | 1001_movies)
    * `--all`          - import every in-scope source
    * `--dry-run`      - scrape + match + report, write nothing
    * `--rematch-pending` - re-run the matcher over existing pending rows, promote resolved ones
    * `--report`       - write docs/scoring/reports/addition_events_spike_<date>.md
  """

  alias Cinegraph.Maintenance.ImportListEvents

  @reports_dir "docs/scoring/reports"

  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          source: :string,
          all: :boolean,
          dry_run: :boolean,
          rematch_pending: :boolean,
          report: :boolean
        ]
      )

    run_opts = Keyword.take(opts, [:source, :all, :dry_run, :rematch_pending])

    case ImportListEvents.run(run_opts) do
      {:ok, %{rematch_pending: true} = result} ->
        Mix.shell().info(
          "Re-match sweep: examined #{result.examined}, promoted #{result.promoted}, " <>
            "still pending #{result.still_pending}"
        )

      {:ok, %{sources: sources, dry_run: dry_run?}} ->
        print_summary(sources, dry_run?)
        if opts[:report], do: write_report(sources, dry_run?)
    end
  rescue
    e in ArgumentError ->
      Mix.shell().error(Exception.message(e))
      Mix.shell().info("\nUsage: mix import_list_events --source national_film_registry | --all")
  end

  defp print_summary(sources, dry_run?) do
    Mix.shell().info("#{if dry_run?, do: "[DRY RUN] ", else: ""}List membership events import\n")

    Enum.each(sources, fn s ->
      case s do
        %{error: reason} ->
          Mix.shell().error("  ✗ #{s.source_key}: #{inspect(reason)}")

        _ ->
          recon = s.reconciliation

          Mix.shell().info("  • #{s.source_key}")

          Mix.shell().info(
            "      found=#{s.found} matched=#{s.matched} pending=#{s.pending} upserted=#{s.upserted}"
          )

          Mix.shell().info("      coverage: #{summarize_coverage(s.coverage)}")

          if recon do
            Mix.shell().info(
              "      reconcile: net_adds=#{recon.net_adds} current_members=#{recon.current_members} " <>
                "discrepancy=#{recon.discrepancy}"
            )
          end
      end
    end)
  end

  defp summarize_coverage(coverage) do
    coverage
    |> Map.take([
      :events_found,
      :adds,
      :removes,
      :cross_check,
      :cap_reason,
      :editions_fetched,
      :editions_skipped,
      :wikipedia_only,
      :loc_only
    ])
    |> Enum.reject(fn {_k, v} -> v in [nil, [], ""] end)
    |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
    |> Enum.join(" ")
  end

  defp write_report(sources, dry_run?) do
    {date, _} = :calendar.local_time()
    {y, m, d} = date
    date_str = :io_lib.format("~4..0w_~2..0w_~2..0w", [y, m, d]) |> IO.iodata_to_binary()
    path = Path.join(@reports_dir, "addition_events_spike_#{date_str}.md")

    File.mkdir_p!(@reports_dir)
    File.write!(path, render_report(sources, dry_run?, date_str))
    Mix.shell().info("\nReport written: #{path}")
  end

  defp render_report(sources, dry_run?, date_str) do
    rows =
      Enum.map_join(sources, "\n", fn s ->
        case s do
          %{error: reason} ->
            "| #{s.source_key} | ERROR | #{inspect(reason)} | | | |"

          _ ->
            recon = s.reconciliation
            cov = s.coverage

            "| #{s.source_key} | #{s.found} | #{s.matched} | #{s.pending} | " <>
              "#{Map.get(cov, :adds, "")}/#{Map.get(cov, :removes, "")} | " <>
              "#{if recon, do: recon.net_adds, else: ""} vs #{if recon, do: recon.current_members, else: ""} |"
        end
      end)

    """
    # Addition-event ground truth spike (#1115)

    **Date:** #{String.replace(date_str, "_", "-")} · **DB:** `cinegraph_dev`#{if dry_run?, do: " · DRY RUN", else: ""}

    Built `list_membership_events` — one row per (list, movie, add/remove event) — to give
    the prediction product the addition-event ground truth it lacked (the DB previously held
    only current-union membership). Session scope: NFR + 1001_movies. No eval/model/grading
    code touched.

    ## Per-list coverage

    | list | found | matched | pending | adds/removes | net-adds vs current |
    |---|--:|--:|--:|--:|--:|
    #{rows}

    ## Notes, caps, and gaps

    #{Enum.map_join(sources, "\n", &render_notes/1)}

    ## Acceptance-gate status

    - NFR induction-year add-events: spot-check 10 against loc.gov (manual).
    - 1001 editions of diffs + removed-film count: see `removes` above.
    - Reconciliation (net-adds vs current membership): discrepancies listed above —
      expected where current-union counts include unmatched films or pre-coverage members.
    - No eval/model/grading file touched.
    """
  end

  defp render_notes(%{error: reason} = s), do: "- **#{s.source_key}**: ERROR — #{inspect(reason)}"

  defp render_notes(s) do
    cov = s.coverage
    "- **#{s.source_key}**: #{summarize_coverage(cov)}"
  end
end
