defmodule Cinegraph.Movies.MovieVideo do
  use Ecto.Schema
  import Ecto.Changeset

  schema "movie_videos" do
    belongs_to :movie, Cinegraph.Movies.Movie

    field :tmdb_id, :string
    field :name, :string
    field :key, :string
    field :site, :string
    field :type, :string
    field :size, :integer
    field :official, :boolean, default: false
    field :published_at, :naive_datetime

    timestamps()
  end

  @doc false
  def changeset(video, attrs) do
    video
    |> cast(attrs, [
      :movie_id,
      :tmdb_id,
      :name,
      :key,
      :site,
      :type,
      :size,
      :official,
      :published_at
    ])
    |> validate_required([:movie_id, :tmdb_id, :key, :site, :type])
    |> unique_constraint(:tmdb_id)
    |> foreign_key_constraint(:movie_id)
  end

  @doc """
  Creates a changeset from TMDB API response data
  """
  def from_tmdb(attrs, movie_id) do
    video_attrs = %{
      movie_id: movie_id,
      tmdb_id: attrs["id"],
      name: attrs["name"],
      key: attrs["key"],
      site: attrs["site"],
      type: attrs["type"],
      size: attrs["size"],
      official: attrs["official"],
      published_at: parse_datetime(attrs["published_at"])
    }

    changeset(%__MODULE__{}, video_attrs)
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _} -> datetime
      {:error, _} -> nil
    end
  end
end
