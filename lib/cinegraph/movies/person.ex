defmodule Cinegraph.Movies.Person do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "people" do
    field :tmdb_id, :integer
    field :imdb_id, :string
    field :name, :string
    field :gender, :integer
    field :birthday, :date
    field :deathday, :date
    field :place_of_birth, :string
    field :biography, :string
    field :known_for_department, :string
    field :adult, :boolean, default: false
    field :popularity, :float
    
    # Images
    field :profile_path, :string
    
    # Associations
    has_many :credits, Cinegraph.Movies.Credit, foreign_key: :person_id
    many_to_many :movies, Cinegraph.Movies.Movie, join_through: Cinegraph.Movies.Credit
    
    timestamps()
  end

  @doc false
  def changeset(person, attrs) do
    person
    |> cast(attrs, [
      :tmdb_id, :imdb_id, :name, :gender,
      :birthday, :deathday, :place_of_birth, :biography,
      :known_for_department, :adult, :popularity, :profile_path
    ])
    |> validate_required([:tmdb_id, :name])
    |> unique_constraint(:tmdb_id)
  end

  @doc """
  Changeset for creating person records from IMDb data only.
  Used when we only have IMDb ID and name, without TMDb data.
  """
  def imdb_changeset(person, attrs) do
    person
    |> cast(attrs, [:imdb_id, :name])
    |> validate_required([:imdb_id, :name])
    |> unique_constraint(:imdb_id)
  end

  @doc """
  Creates a changeset from TMDB API response data
  """
  def from_tmdb(attrs) do
    person_attrs = %{
      tmdb_id: attrs["id"],
      imdb_id: attrs["imdb_id"],
      name: attrs["name"],
      gender: attrs["gender"],
      birthday: parse_date(attrs["birthday"]),
      deathday: parse_date(attrs["deathday"]),
      place_of_birth: attrs["place_of_birth"],
      biography: attrs["biography"],
      known_for_department: attrs["known_for_department"],
      adult: attrs["adult"],
      popularity: attrs["popularity"],
      profile_path: attrs["profile_path"]
    }
    
    changeset(%__MODULE__{}, person_attrs)
  end

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil
  defp parse_date(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  @doc """
  Returns the gender as a human-readable string
  """
  def gender_string(%__MODULE__{gender: gender}) do
    case gender do
      1 -> "Female"
      2 -> "Male"
      3 -> "Non-binary"
      _ -> "Not specified"
    end
  end

  @doc """
  Builds the full URL for a profile image
  """
  def profile_url(%__MODULE__{profile_path: nil}), do: nil
  def profile_url(%__MODULE__{profile_path: path}, size \\ "w185") do
    "https://image.tmdb.org/t/p/#{size}#{path}"
  end
end