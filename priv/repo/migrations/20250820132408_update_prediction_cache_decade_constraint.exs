defmodule Cinegraph.Repo.Migrations.UpdatePredictionCacheDecadeConstraint do
  use Ecto.Migration

  def up do
    # Add new constraint with all decades from 1920s to 2020s
    # (there's no existing constraint to drop based on \d+ output)
    create constraint(:prediction_cache, :prediction_cache_decade_check,
             check:
               "decade = ANY(ARRAY[1920, 1930, 1940, 1950, 1960, 1970, 1980, 1990, 2000, 2010, 2020])"
           )
  end

  def down do
    # Remove the constraint we added
    drop constraint(:prediction_cache, :prediction_cache_decade_check)
  end
end
