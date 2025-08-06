defmodule Cinegraph.Repo.Migrations.AddFestivalIndexes do
  use Ecto.Migration

  def up do
    # Most indexes already exist from the original migration
    # Only add what's missing:
    
    # Add partial index for wins with ceremony_id for better performance
    create index(:festival_nominations, [:ceremony_id, :won], 
      where: "won = true",
      name: :festival_nominations_ceremony_won_true_idx
    )
    
    # Add unique constraint to prevent duplicate nominations
    # (This is the main missing piece for data integrity)
    create unique_index(:festival_nominations, [:ceremony_id, :category_id, :movie_id],
      name: :festival_nominations_unique_nomination_idx
    )
  end

  def down do
    drop index(:festival_nominations, [:ceremony_id, :won], 
      name: :festival_nominations_ceremony_won_true_idx
    )
    drop unique_index(:festival_nominations, [:ceremony_id, :category_id, :movie_id],
      name: :festival_nominations_unique_nomination_idx
    )
  end
end