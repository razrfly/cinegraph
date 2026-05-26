defmodule Cinegraph.Repo.Migrations.AddProductionCompanyIdIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # The only existing index on movie_production_companies starts with movie_id,
    # making JOIN ON production_company_id = c.id a seq scan. This covers that direction.
    create_if_not_exists index(
                           :movie_production_companies,
                           [:production_company_id],
                           name: :movie_production_companies_company_id_idx,
                           concurrently: true
                         )
  end
end
