defmodule Cinegraph.Cultural.Authority do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  schema "cultural_authorities" do
    field :name, :string
    field :authority_type, :string
    field :category, :string
    field :trust_score, :float, default: 0.5
    field :base_weight, :float, default: 1.0
    field :description, :string
    field :homepage, :string
    field :country_code, :string
    field :established_year, :integer
    field :last_sync_at, :utc_datetime
    field :sync_frequency, :string
    field :data_source, :string

    has_many :curated_lists, Cinegraph.Cultural.CuratedList, foreign_key: :authority_id

    timestamps()
  end

  @authority_types ~w(award collection critic platform)
  @sync_frequencies ~w(daily weekly monthly annual)
  @data_sources ~w(api scraper manual wikidata omdb)

  @doc false
  def changeset(authority, attrs) do
    authority
    |> cast(attrs, [
      :name, :authority_type, :category, :trust_score, :base_weight,
      :description, :homepage, :country_code, :established_year,
      :last_sync_at, :sync_frequency, :data_source
    ])
    |> validate_required([:name, :authority_type])
    |> validate_inclusion(:authority_type, @authority_types)
    |> validate_inclusion(:sync_frequency, @sync_frequencies)
    |> validate_inclusion(:data_source, @data_sources)
    |> validate_number(:trust_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:base_weight, greater_than: 0.0)
    |> validate_length(:country_code, is: 2)
    |> unique_constraint(:name)
  end
end