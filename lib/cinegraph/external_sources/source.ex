defmodule Cinegraph.ExternalSources.Source do
  use Ecto.Schema
  import Ecto.Changeset

  schema "external_sources" do
    field :name, :string
    field :source_type, :string
    field :base_url, :string
    field :api_version, :string
    field :weight_factor, :float, default: 1.0
    field :active, :boolean, default: true
    field :config, :map, default: %{}

    has_many :ratings, Cinegraph.ExternalSources.Rating
    has_many :recommendations, Cinegraph.ExternalSources.Recommendation

    timestamps()
  end

  @doc false
  def changeset(source, attrs) do
    source
    |> cast(attrs, [
      :name,
      :source_type,
      :base_url,
      :api_version,
      :weight_factor,
      :active,
      :config
    ])
    |> validate_required([:name])
    |> unique_constraint(:name)
    |> validate_inclusion(:source_type, ["api", "scraper", "manual"])
    |> validate_number(:weight_factor, greater_than: 0.0)
  end
end
