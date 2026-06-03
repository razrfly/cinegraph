defmodule Cinegraph.Repo.Migrations.DropBacktestStrategyFromMovieLists do
  use Ecto.Migration

  # #1051 Stage 0 — `movie_lists.backtest_strategy` is a dead column: written nowhere and
  # read nowhere. The authoritative backtest strategy lives on
  # `prediction_models.backtest_strategy`. Drop it. (`remove/2` with the type makes the
  # change reversible — rollback re-adds the column.)
  def change do
    alter table(:movie_lists) do
      remove :backtest_strategy, :string
    end
  end
end
