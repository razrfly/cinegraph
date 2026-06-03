defmodule Cinegraph.Repo.Migrations.DeferPriorCollabDensity do
  use Ecto.Migration

  # #1040 Session 2 — `prior_collab_density` is the one derived feature NOT shipped this session
  # (it needs per-movie wiring of the person×year `person_collaboration_trends` matview, a separate
  # data path). Mark it unavailable so the catalog doesn't advertise a feature the data-point
  # surface can't emit. The training routing already gates on DerivedFeatures.supported_codes/0;
  # this keeps `metric_definitions` honest. Re-enable when the feature is wired.
  def up do
    execute(
      "UPDATE metric_definitions SET is_available = false WHERE code = 'prior_collab_density'"
    )
  end

  def down do
    execute(
      "UPDATE metric_definitions SET is_available = true WHERE code = 'prior_collab_density'"
    )
  end
end
