defmodule Cinegraph.Repo.Migrations.EnablePriorCollabDensity do
  use Ecto.Migration

  # #1044 — `prior_collab_density` is now wired: `Cinegraph.Scoring.DerivedFeatures` emits it from
  # the person×year `person_collaboration_trends` matview (prior-to-release collaboration density),
  # and it is in `DerivedFeatures.supported_codes/0`. Re-enable the catalog flag the defer migration
  # (20260603120300) flipped off, so `metric_definitions` once again advertises a feature the
  # data-point surface really emits.
  def up do
    execute(
      "UPDATE metric_definitions SET is_available = true WHERE code = 'prior_collab_density'"
    )
  end

  def down do
    execute(
      "UPDATE metric_definitions SET is_available = false WHERE code = 'prior_collab_density'"
    )
  end
end
