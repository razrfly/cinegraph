defmodule Cinegraph.Movies.Credit do
  use Ecto.Schema
  import Ecto.Changeset

  schema "movie_credits" do
    field :credit_type, :string
    field :character, :string
    field :cast_order, :integer
    field :department, :string
    field :job, :string
    field :credit_id, :string
    
    # Associations
    belongs_to :movie, Cinegraph.Movies.Movie
    belongs_to :person, Cinegraph.Movies.Person
    
    timestamps()
  end

  @doc false
  def changeset(credit, attrs) do
    credit
    |> cast(attrs, [
      :movie_id, :person_id, :credit_type, :character,
      :cast_order, :department, :job, :credit_id
    ])
    |> validate_required([:movie_id, :person_id, :credit_type])
    |> validate_inclusion(:credit_type, ["cast", "crew"])
    |> foreign_key_constraint(:movie_id)
    |> foreign_key_constraint(:person_id)
  end

  @doc """
  Creates a cast member changeset from TMDB API response data
  """
  def from_tmdb_cast(attrs, movie_id, person_id) do
    credit_attrs = %{
      movie_id: movie_id,
      person_id: person_id,
      credit_type: "cast",
      character: attrs["character"],
      cast_order: attrs["order"],
      credit_id: attrs["credit_id"]
    }
    
    changeset(%__MODULE__{}, credit_attrs)
  end

  @doc """
  Creates a crew member changeset from TMDB API response data
  """
  def from_tmdb_crew(attrs, movie_id, person_id) do
    credit_attrs = %{
      movie_id: movie_id,
      person_id: person_id,
      credit_type: "crew",
      department: attrs["department"],
      job: attrs["job"],
      credit_id: attrs["credit_id"]
    }
    
    changeset(%__MODULE__{}, credit_attrs)
  end
end