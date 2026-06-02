defmodule Cinegraph.Repo.Migrations.AddLensConfigHashToMovieScoreCaches do
  use Ecto.Migration

  # #1036 closeout: cache traceability. Records which lens configuration produced each cache
  # row, alongside calculation_version. Nullable + additive — existing rows backfill on the
  # next `mix cinegraph.scoring.rewarm`; no calculation_version bump needed.
  def change do
    alter table(:movie_score_caches) do
      add :lens_config_hash, :string
    end
  end
end
