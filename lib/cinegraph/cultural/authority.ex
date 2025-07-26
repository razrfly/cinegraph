defmodule Cinegraph.Cultural.Authority do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  schema "cultural_authorities" do
    field :name, :string
    field :authority_type, :string
    field :description, :string
    field :website, :string
    field :trust_score, :float, default: 5.0
    field :active, :boolean, default: true
    field :metadata, :map

    has_many :curated_lists, Cinegraph.Cultural.CuratedList, foreign_key: :authority_id

    timestamps()
  end

  @authority_types ~w(award collection critic platform)

  @doc false
  def changeset(authority, attrs) do
    authority
    |> cast(attrs, [
      :name, :authority_type, :description, :website, 
      :trust_score, :active, :metadata
    ])
    |> validate_required([:name, :authority_type])
    |> validate_inclusion(:authority_type, @authority_types)
    |> validate_number(:trust_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 10.0)
    |> unique_constraint(:name)
  end
end