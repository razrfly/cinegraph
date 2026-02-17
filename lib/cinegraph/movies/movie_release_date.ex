defmodule Cinegraph.Movies.MovieReleaseDate do
  use Ecto.Schema
  import Ecto.Changeset

  schema "movie_release_dates" do
    belongs_to :movie, Cinegraph.Movies.Movie

    field :country_code, :string
    field :release_date, :naive_datetime
    field :certification, :string
    field :release_type, :integer
    field :note, :string

    timestamps()
  end

  @doc false
  def changeset(release_date, attrs) do
    release_date
    |> cast(attrs, [:movie_id, :country_code, :release_date, :certification, :release_type, :note])
    |> validate_required([:movie_id, :country_code])
    |> validate_inclusion(:release_type, 1..6)
    |> unique_constraint([:movie_id, :country_code, :release_type])
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
        country_code: truncate(country_code, 255),
        release_date: parse_datetime(release["release_date"]),
        certification: truncate(release["certification"], 255),
        release_type: release["type"],
        note: truncate(release["note"], 255)
      }

      changeset(%__MODULE__{}, release_attrs)
    end)
  end

  defp truncate(nil, _max), do: nil
  defp truncate(str, max) when is_binary(str) and byte_size(str) > max, do: String.slice(str, 0, max)
  defp truncate(str, _max), do: str

  defp parse_datetime(nil), do: nil

  defp parse_datetime(datetime_string) do
    case NaiveDateTime.from_iso8601(datetime_string) do
      {:ok, datetime} ->
        datetime

      {:error, _} ->
        # Try parsing as date only
        case Date.from_iso8601(datetime_string) do
          {:ok, date} -> NaiveDateTime.new!(date, ~T[00:00:00])
          {:error, _} -> nil
        end
    end
  end
end
