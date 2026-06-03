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

  Oban is left **enabled** (the `:start_oban` flag is untouched) so tasks that
  enqueue jobs — e.g. the OMDb backfill — can still drain them.

  Call this in place of `Mix.Task.run("app.start")`, before any Repo use.
  """
  def start_lean do
    Application.put_env(:cinegraph, :start_background_children, false)
    Mix.Task.run("app.start")
  end
end
