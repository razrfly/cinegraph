defmodule Cinegraph.Movies.MovieReleaseDate do
  use Ecto.Schema
  import Ecto.Changeset

  schema "movie_release_dates" do
    belongs_to :movie, Cinegraph.Movies.Movie
    
    field :country_code, :string
    field :release_date, :utc_datetime
    field :certification, :string
    field :type, :integer
    field :note, :string
    
    timestamps()
  end

  @doc false
  def changeset(release_date, attrs) do
    release_date
    |> cast(attrs, [:movie_id, :country_code, :release_date, :certification, :type, :note])
    |> validate_required([:movie_id, :country_code])
    |> validate_inclusion(:type, 1..6)
    |> unique_constraint([:movie_id, :country_code, :type])
    |> foreign_key_constraint(:movie_id)
  end

  @doc """
  Creates changesets from TMDB API response data
  """
  def from_tmdb_country(country_data, movie_id) do
    country_code = country_data["iso_3166_1"]
    
    country_data["release_dates"]
    |> Enum.map(fn release ->
      release_attrs = %{
        movie_id: movie_id,
        country_code: country_code,
        release_date: parse_datetime(release["release_date"]),
        certification: release["certification"],
        type: release["type"],
        note: release["note"]
      }
      
      changeset(%__MODULE__{}, release_attrs)
    end)
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _} -> datetime
      {:error, _} -> nil
    end
  end
end