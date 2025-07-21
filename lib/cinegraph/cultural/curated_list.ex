defmodule Cinegraph.Cultural.CuratedList do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  schema "curated_lists" do
    field :name, :string
    field :list_type, :string
    field :year, :integer
    field :total_items, :integer
    field :description, :string
    field :selection_criteria, :string
    field :prestige_score, :float
    field :cultural_impact, :float

    belongs_to :authority, Cinegraph.Cultural.Authority, foreign_key: :authority_id
    has_many :movie_list_items, Cinegraph.Cultural.MovieListItem, foreign_key: :list_id

    timestamps()
  end

  @list_types ~w(ranked unranked award collection)

  @doc false
  def changeset(curated_list, attrs) do
    curated_list
    |> cast(attrs, [
      :authority_id, :name, :list_type, :year, :total_items,
      :description, :selection_criteria, :prestige_score, :cultural_impact
    ])
    |> validate_required([:authority_id, :name])
    |> validate_inclusion(:list_type, @list_types)
    |> validate_number(:year, greater_than: 1900, less_than_or_equal_to: 2030)
    |> validate_number(:prestige_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:cultural_impact, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:authority_id)
    |> unique_constraint([:authority_id, :name, :year])
  end
end