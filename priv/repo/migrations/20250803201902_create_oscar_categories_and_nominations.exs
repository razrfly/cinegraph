defmodule Cinegraph.Repo.Migrations.CreateOscarCategoriesAndNominations do
  use Ecto.Migration

  def change do
    # Create oscar_categories table
    create table(:oscar_categories) do
      add :name, :text, null: false
      add :category_type, :text, null: false # 'person', 'film', 'technical'
      add :is_major, :boolean, default: false
      add :tracks_person, :boolean, default: false # true only for actor/director awards
      
      timestamps()
    end
    
    create unique_index(:oscar_categories, [:name])
    
    # Create oscar_nominations table
    create table(:oscar_nominations) do
      add :ceremony_id, references(:oscar_ceremonies, on_delete: :delete_all), null: false
      add :category_id, references(:oscar_categories, on_delete: :restrict), null: false
      add :movie_id, references(:movies, on_delete: :delete_all)
      add :person_id, references(:people, on_delete: :delete_all)
      add :won, :boolean, null: false, default: false
      add :details, :jsonb, default: "{}"
      
      timestamps()
    end
    
    # Indexes for fast queries
    create index(:oscar_nominations, [:movie_id])
    create index(:oscar_nominations, [:person_id])
    create index(:oscar_nominations, [:won], where: "won = true")
    create index(:oscar_nominations, [:ceremony_id, :category_id])
    
    # Unique constraint to prevent duplicate nominations
    create unique_index(:oscar_nominations, [:ceremony_id, :category_id, :movie_id])
    
    # Ensure we have either a movie or person (or both)
    create constraint(:oscar_nominations, :must_have_movie_or_person, 
      check: "movie_id IS NOT NULL OR person_id IS NOT NULL")
    
    # Insert the standard Oscar categories
    execute """
    INSERT INTO oscar_categories (name, category_type, is_major, tracks_person, inserted_at, updated_at) VALUES
    -- Person-trackable categories (single person awards)
    ('Actor in a Leading Role', 'person', true, true, NOW(), NOW()),
    ('Actor in a Supporting Role', 'person', true, true, NOW(), NOW()),
    ('Actress in a Leading Role', 'person', true, true, NOW(), NOW()),
    ('Actress in a Supporting Role', 'person', true, true, NOW(), NOW()),
    ('Directing', 'person', true, true, NOW(), NOW()),
    
    -- Film-only categories (multiple people or technical)
    ('Best Picture', 'film', true, false, NOW(), NOW()),
    ('Animated Feature Film', 'film', false, false, NOW(), NOW()),
    ('Animated Short Film', 'film', false, false, NOW(), NOW()),
    ('Cinematography', 'technical', false, false, NOW(), NOW()),
    ('Costume Design', 'technical', false, false, NOW(), NOW()),
    ('Documentary Feature Film', 'film', false, false, NOW(), NOW()),
    ('Documentary Short Film', 'film', false, false, NOW(), NOW()),
    ('Film Editing', 'technical', false, false, NOW(), NOW()),
    ('International Feature Film', 'film', false, false, NOW(), NOW()),
    ('Live Action Short Film', 'film', false, false, NOW(), NOW()),
    ('Makeup and Hairstyling', 'technical', false, false, NOW(), NOW()),
    ('Music (Original Score)', 'technical', false, false, NOW(), NOW()),
    ('Music (Original Song)', 'technical', false, false, NOW(), NOW()),
    ('Production Design', 'technical', false, false, NOW(), NOW()),
    ('Short Film (Animated)', 'film', false, false, NOW(), NOW()),
    ('Short Film (Live Action)', 'film', false, false, NOW(), NOW()),
    ('Sound', 'technical', false, false, NOW(), NOW()),
    ('Visual Effects', 'technical', false, false, NOW(), NOW()),
    ('Writing (Adapted Screenplay)', 'technical', false, false, NOW(), NOW()),
    ('Writing (Original Screenplay)', 'technical', false, false, NOW(), NOW())
    """
  end
end
