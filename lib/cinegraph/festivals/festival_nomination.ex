defmodule Cinegraph.Festivals.FestivalNomination do
  @moduledoc """
  Schema for festival nominations.
  Replaces the old OscarNomination table.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "festival_nominations" do
    belongs_to :ceremony, Cinegraph.Festivals.FestivalCeremony
    belongs_to :category, Cinegraph.Festivals.FestivalCategory
    belongs_to :movie, Cinegraph.Movies.Movie
    belongs_to :person, Cinegraph.Movies.Person

    field :won, :boolean, default: false
    field :details, :map
    
    # Fields for pending nominations (movie doesn't exist yet)
    field :movie_imdb_id, :string
    field :movie_title, :string
    
    # Fields for pending nominations (person doesn't exist yet)
    field :person_imdb_ids, {:array, :string}, default: []
    field :person_name, :string

    timestamps()
  end

  @doc false
  def changeset(nomination, attrs) do
    nomination
    |> cast(attrs, [:ceremony_id, :category_id, :movie_id, :person_id, :won, :details, 
                    :movie_imdb_id, :movie_title, :person_imdb_ids, :person_name])
    |> validate_required([:ceremony_id, :category_id])
    # Either movie_id OR movie_imdb_id must be present
    |> validate_movie_reference()
    |> foreign_key_constraint(:ceremony_id)
    |> foreign_key_constraint(:category_id)
    |> foreign_key_constraint(:movie_id)
    |> foreign_key_constraint(:person_id)
    # Add unique constraint checks to prevent duplicates
    |> unique_constraint([:ceremony_id, :category_id, :movie_id, :person_name], 
                         name: :festival_nominations_unique_person_idx,
                         message: "nomination already exists for this person")
    |> unique_constraint([:ceremony_id, :category_id, :movie_id], 
                         name: :festival_nominations_unique_film_idx,
                         message: "nomination already exists for this film")
    |> unique_constraint([:ceremony_id, :category_id, :movie_imdb_id, :person_name],
                         name: :festival_nominations_unique_pending_person_idx,
                         message: "pending nomination already exists for this person")
    |> unique_constraint([:ceremony_id, :category_id, :movie_imdb_id],
                         name: :festival_nominations_unique_pending_film_idx,
                         message: "pending nomination already exists for this film")
  end
  
  # Custom validation to ensure we have either a movie_id or movie_imdb_id
  defp validate_movie_reference(changeset) do
    movie_id = get_change(changeset, :movie_id) || get_field(changeset, :movie_id)
    movie_imdb_id = get_change(changeset, :movie_imdb_id) || get_field(changeset, :movie_imdb_id)
    
    if is_nil(movie_id) and is_nil(movie_imdb_id) do
      add_error(changeset, :movie_id, "either movie_id or movie_imdb_id must be present")
    else
      changeset
    end
  end
end
