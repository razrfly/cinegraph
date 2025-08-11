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
    
    # New fields for better tracking
    field :movie_imdb_id, :string
    field :person_imdb_ids, {:array, :string}, default: []
    field :person_name, :string
    field :prize_name, :string

    timestamps()
  end

  @doc false
  def changeset(nomination, attrs) do
    nomination
    |> cast(attrs, [:ceremony_id, :category_id, :movie_id, :person_id, :won, :details,
                    :movie_imdb_id, :person_imdb_ids, :person_name, :prize_name])
    |> validate_required([:ceremony_id, :category_id])
    # Either movie_id OR movie_imdb_id is required
    |> validate_movie_or_imdb_id()
    |> foreign_key_constraint(:ceremony_id)
    |> foreign_key_constraint(:category_id)
    |> foreign_key_constraint(:movie_id)
    |> foreign_key_constraint(:person_id)
  end
  
  defp validate_movie_or_imdb_id(changeset) do
    movie_id = get_field(changeset, :movie_id)
    movie_imdb_id = get_field(changeset, :movie_imdb_id)
    
    if is_nil(movie_id) and is_nil(movie_imdb_id) do
      add_error(changeset, :movie_id, "either movie_id or movie_imdb_id is required")
    else
      changeset
    end
  end
end
