defmodule Cinegraph.Metrics.MetricWeightProfile do
  @moduledoc """
  Schema for weight profiles that define different scoring strategies for movie metrics.

  Weight profiles allow different approaches to scoring movies (critics choice, crowd pleaser, etc.)
  by adjusting the relative importance of different categories and individual metrics.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  schema "metric_weight_profiles" do
    field :name, :string
    field :description, :string

    # Individual metric weights by metric code
    field :weights, :map, default: %{}
    # Example: {"imdb_rating" => 1.0, "oscar_wins" => 2.0, "revenue_worldwide" => 0.8}

    # Category multipliers (applied after individual weights)
    field :category_weights, :map,
      default: %{
        "ratings" => 1.0,
        "awards" => 1.0,
        "financial" => 1.0,
        "cultural" => 1.0,
        "people" => 1.0
      }

    # Usage tracking
    field :usage_count, :integer, default: 0
    field :last_used_at, :utc_datetime

    # Status
    field :active, :boolean, default: true
    field :is_default, :boolean, default: false
    field :is_system, :boolean, default: false

    # Associations
    has_many :metric_scores, Cinegraph.Metrics.MetricScore, foreign_key: :profile_id

    timestamps()
  end

  @doc false
  def changeset(weight_profile, attrs) do
    weight_profile
    |> cast(attrs, [
      :name,
      :description,
      :weights,
      :category_weights,
      :active,
      :is_default,
      :is_system
    ])
    |> validate_required([:name, :weights])
    |> unique_constraint(:name)
    |> validate_category_weights()
    |> validate_only_one_default()
  end

  defp validate_category_weights(changeset) do
    case get_change(changeset, :category_weights) do
      nil ->
        changeset

      weights ->
        valid_categories = ["ratings", "awards", "financial", "cultural", "people"]

        cond do
          not Enum.all?(Map.keys(weights), &(&1 in valid_categories)) ->
            add_error(changeset, :category_weights, "contains invalid categories")

          not Enum.all?(Map.values(weights), &(is_number(&1) and &1 >= 0)) ->
            add_error(changeset, :category_weights, "weights must be non-negative numbers")

          true ->
            changeset
        end
    end
  end

  defp validate_only_one_default(changeset) do
    if get_change(changeset, :is_default) == true do
      # Check if another default exists
      import Ecto.Query
      current_id = changeset.data.id

      query =
        case current_id do
          nil -> from p in __MODULE__, where: p.is_default == true
          id -> from p in __MODULE__, where: p.is_default == true and p.id != ^id
        end

      case Cinegraph.Repo.one(query) do
        nil -> changeset
        _ -> add_error(changeset, :is_default, "only one profile can be default")
      end
    else
      changeset
    end
  end
end
