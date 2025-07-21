defmodule Cinegraph.Cultural.MovieDataChange do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  schema "movie_data_changes" do
    field :source_platform, :string
    field :change_type, :string
    field :change_count, :integer
    field :period_start, :utc_datetime
    field :period_end, :utc_datetime
    field :change_velocity, :float
    field :unusual_activity, :boolean

    belongs_to :movie, Cinegraph.Movies.Movie, foreign_key: :movie_id

    timestamps()
  end

  @source_platforms ~w(tmdb letterboxd imdb rotten_tomatoes metacritic)
  @change_types ~w(rating_change view_count_spike list_additions review_surge social_mention)

  @doc false
  def changeset(change, attrs) do
    change
    |> cast(attrs, [
      :movie_id, :source_platform, :change_type, :change_count,
      :period_start, :period_end, :change_velocity, :unusual_activity
    ])
    |> validate_required([:movie_id, :source_platform, :change_type])
    |> validate_inclusion(:source_platform, @source_platforms)
    |> validate_inclusion(:change_type, @change_types)
    |> validate_number(:change_count, greater_than_or_equal_to: 0)
    |> validate_number(:change_velocity, greater_than_or_equal_to: 0.0)
    |> foreign_key_constraint(:movie_id)
  end
end