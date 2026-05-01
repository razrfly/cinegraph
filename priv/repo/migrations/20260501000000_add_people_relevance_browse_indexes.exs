defmodule Cinegraph.Repo.Migrations.AddPeopleRelevanceBrowseIndexes do
  use Ecto.Migration

  def change do
    create_if_not_exists index(:person_metrics, [:metric_type, :score, :person_id],
                           name: :person_metrics_quality_score_sort_idx,
                           where: "metric_type = 'quality_score'"
                         )

    create_if_not_exists index(:people, [:adult, :known_for_department],
                           name: :people_adult_department_idx
                         )
  end
end
