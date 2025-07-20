defmodule Cinegraph.Movies.Person do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "people" do
    field :tmdb_id, :integer
    field :imdb_id, :string
    field :name, :string
    field :also_known_as, {:array, :string}, default: []
    field :gender, :integer
    field :birthday, :date
    field :deathday, :date
    field :place_of_birth, :string
    field :biography, :string
    field :popularity, :float
    field :known_for_department, :string
    field :adult, :boolean, default: false
    field :homepage, :string
    
    # Images
    field :profile_path, :string
    field :images, :map, default: %{}
    
    # External IDs
    field :external_ids, :map, default: %{}
    
    # Metadata
    field :tmdb_raw_data, :map
    field :tmdb_fetched_at, :utc_datetime
    field :tmdb_last_updated, :utc_datetime
    
    # CRI influence metrics
    field :influence_score, :float
    field :career_longevity_score, :float
    field :cross_cultural_impact, :float
    
    # Associations
    has_many :credits, Cinegraph.Movies.Credit, foreign_key: :person_id
    many_to_many :movies, Cinegraph.Movies.Movie, join_through: Cinegraph.Movies.Credit
    
    timestamps()
  end

  @doc false
  def changeset(person, attrs) do
    person
    |> cast(attrs, [
      :tmdb_id, :imdb_id, :name, :also_known_as, :gender,
      :birthday, :deathday, :place_of_birth, :biography,
      :popularity, :known_for_department, :adult, :homepage,
      :profile_path, :images, :external_ids, :tmdb_raw_data,
      :tmdb_fetched_at, :tmdb_last_updated, :influence_score,
      :career_longevity_score, :cross_cultural_impact
    ])
    |> validate_required([:tmdb_id, :name])
    |> unique_constraint(:tmdb_id)
  end

  @doc """
  Creates a changeset from TMDB API response data
  """
  def from_tmdb(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    
    person_attrs = %{
      tmdb_id: attrs["id"],
      imdb_id: attrs["imdb_id"],
      name: attrs["name"],
      also_known_as: attrs["also_known_as"] || [],
      gender: attrs["gender"],
      birthday: parse_date(attrs["birthday"]),
      deathday: parse_date(attrs["deathday"]),
      place_of_birth: attrs["place_of_birth"],
      biography: attrs["biography"],
      popularity: attrs["popularity"],
      known_for_department: attrs["known_for_department"],
      adult: attrs["adult"],
      homepage: attrs["homepage"],
      profile_path: attrs["profile_path"],
      external_ids: attrs["external_ids"] || %{},
      tmdb_raw_data: attrs,
      tmdb_fetched_at: now,
      tmdb_last_updated: now
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