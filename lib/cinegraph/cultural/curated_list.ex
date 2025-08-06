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
    field :source_url, :string
    field :metadata, :map

    belongs_to :authority, Cinegraph.Cultural.Authority, foreign_key: :authority_id
    has_many :movie_list_items, Cinegraph.Cultural.MovieListItem, foreign_key: :list_id

    timestamps()
  end

  @list_types ~w(ranked unranked award collection)

  @doc false
  def changeset(curated_list, attrs) do
    curated_list
    |> cast(attrs, [
      :authority_id,
      :name,
      :list_type,
      :year,
      :total_items,
      :description,
      :source_url,
      :metadata
    ])
    |> validate_required([:authority_id, :name, :list_type])
    |> validate_inclusion(:list_type, @list_types)
    |> validate_number(:year, greater_than: 1900, less_than_or_equal_to: 2030)
    |> foreign_key_constraint(:authority_id)
    |> unique_constraint([:authority_id, :name, :year])
  end
end
