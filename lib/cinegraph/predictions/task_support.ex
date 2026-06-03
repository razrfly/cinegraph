defmodule Cinegraph.Predictions.TaskSupport do
  @moduledoc """
  Shared helpers for the `predictions.*` Mix tasks (#1051 Stage 0).
  """

  @doc """
  Boot the app "lean" for an ad-hoc prediction task.

  The DB-heavy cache warmers (`Cinegraph.Cache.DashboardStats` at boot+10s and
  `Cinegraph.Cache.AwardImportStats` at boot+15s) spawn Tasks that grab the dev
  connection pool (size ~20) and cause 15s checkout timeouts in long-running
  coverage / experiment / backfill runs. They start under the
  `:start_background_children` flag (see `Cinegraph.Application.background_children/0`),
  so disabling that flag before `app.start` keeps them out of the supervision tree.

  Oban is also disabled (`:start_oban` false): none of the `predictions.*` tasks need it —
  the OMDb backfill runner calls `OMDbEnrichmentWorker.perform/1` synchronously, and the
  coverage/experiment/ablation tasks are read-only. Leaving Oban on let queued jobs (e.g.
  festival discovery) drain *during* a diagnostic run, polluting isolation and adding pool
  pressure (#1051 Stage B review). Disabling it keeps diagnostics clean and reproducible.

  Call this in place of `Mix.Task.run("app.start")`, before any Repo use.
  """
  def start_lean do
    Application.put_env(:cinegraph, :start_background_children, false)
    Application.put_env(:cinegraph, :start_oban, false)
    Mix.Task.run("app.start")
  end
end
