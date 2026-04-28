defmodule Cinegraph.Workers.CompletenessSnapshotWorker do
  @moduledoc """
  Daily snapshot of catalog completeness — persists one row to
  `completeness_log` per UTC day. Scheduled via Oban cron at `5 5 * * *`
  (5:05 AM UTC), after the 4 AM TMDb sync settles.

  Also logs the current `Cinegraph.Health.Verdict` rollup (status +
  worst-check) so prod logs carry a daily homeostasis line that's greppable
  for trend tracking (#735 Phase 3.3). The 30-day completeness chart on
  `/admin/health` reads directly from the persisted rows.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias Cinegraph.Health.{Completeness, Facade}

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    case Completeness.run_and_persist() do
      {:ok, log} ->
        log_verdict_summary(log)
        :ok

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp log_verdict_summary(log) do
    verdict = Facade.compute_full_verdict()
    overall = log.payload["overall_completeness_pct"]

    worst_summary =
      case verdict.worst_check do
        nil -> "none"
        w -> "#{w.domain}/#{w.check}=#{w.status}(#{w.affected_pct}%)"
      end

    Logger.info(
      "homeostasis snapshot captured_on=#{log.captured_on} status=#{verdict.status} overall=#{overall}% worst=#{worst_summary}"
    )
  rescue
    e ->
      Logger.warning(
        "homeostasis snapshot verdict log failed:\n" <>
          Exception.format(:error, e, __STACKTRACE__)
      )
  end
end
