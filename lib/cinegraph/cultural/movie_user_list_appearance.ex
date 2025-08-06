defmodule Cinegraph.Cultural.MovieUserListAppearance do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "movie_user_list_appearances" do
    field :platform, :string
    field :total_list_appearances, :integer
    field :quality_weighted_appearances, :float
    field :genre_specific_lists, :integer
    field :award_related_lists, :integer
    field :cultural_lists, :integer
    field :last_calculated, :utc_datetime

    belongs_to :movie, Cinegraph.Movies.Movie, foreign_key: :movie_id, primary_key: true

    timestamps()
  end

  @platforms ~w(tmdb letterboxd imdb)

  @doc false
  def changeset(appearance, attrs) do
    appearance
    |> cast(attrs, [
      :movie_id,
      :platform,
      :total_list_appearances,
      :quality_weighted_appearances,
      :genre_specific_lists,
      :award_related_lists,
      :cultural_lists,
      :last_calculated
    ])
    |> validate_required([:movie_id, :platform])
    |> validate_inclusion(:platform, @platforms)
    |> validate_number(:total_list_appearances, greater_than_or_equal_to: 0)
    |> validate_number(:quality_weighted_appearances, greater_than_or_equal_to: 0.0)
    |> validate_number(:genre_specific_lists, greater_than_or_equal_to: 0)
    |> validate_number(:award_related_lists, greater_than_or_equal_to: 0)
    |> validate_number(:cultural_lists, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:movie_id)
  end
end
