defmodule Cinegraph.Cultural.MovieListItem do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  schema "movie_list_items" do
    field :position, :integer
    field :award_category, :string
    field :award_result, :string
    field :year_awarded, :integer
    field :notes, :string

    belongs_to :movie, Cinegraph.Movies.Movie, foreign_key: :movie_id
    belongs_to :list, Cinegraph.Cultural.CuratedList, foreign_key: :list_id

    timestamps()
  end

  @award_results ~w(winner nominee finalist shortlist)

  @doc false
  def changeset(movie_list_item, attrs) do
    movie_list_item
    |> cast(attrs, [
      :movie_id,
      :list_id,
      :position,
      :award_category,
      :award_result,
      :year_awarded,
      :notes
    ])
    |> validate_required([:movie_id, :list_id])
    |> validate_inclusion(:award_result, @award_results)
    |> validate_number(:position, greater_than: 0)
    |> validate_number(:year_awarded, greater_than: 1900, less_than_or_equal_to: 2030)
    |> foreign_key_constraint(:movie_id)
    |> foreign_key_constraint(:list_id)
    |> unique_constraint([:movie_id, :list_id, :award_category])
  end
end
