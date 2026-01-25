defmodule Cinegraph.Calibration.ScoringConfiguration do
  @moduledoc """
  Schema for scoring configuration versions.

  Stores the complete configuration for how Cinegraph scores are calculated,
  including category weights, normalization methods, and missing data strategies.
  Supports versioning for history and rollback.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @normalization_methods ~w(none bayesian percentile zscore)
  @missing_data_strategies ~w(neutral exclude average penalize)

  @categories ~w(popular_opinion industry_recognition cultural_impact people_quality financial_performance)

  schema "calibration_scoring_configurations" do
    field :version, :integer
    field :name, :string
    field :description, :string
    field :is_active, :boolean, default: false
    field :is_draft, :boolean, default: true

    # Category weights (must sum to 1.0)
    field :category_weights, :map,
      default: %{
        "popular_opinion" => 0.20,
        "industry_recognition" => 0.20,
        "cultural_impact" => 0.20,
        "people_quality" => 0.20,
        "financial_performance" => 0.20
      }

    # Global normalization
    field :normalization_method, :string, default: "none"
    field :normalization_settings, :map, default: %{}

    # Per-category missing data handling
    field :missing_data_strategies, :map,
      default: %{
        "popular_opinion" => "neutral",
        "industry_recognition" => "exclude",
        "cultural_impact" => "neutral",
        "people_quality" => "average",
        "financial_performance" => "exclude"
      }

    field :deployed_at, :utc_datetime

    timestamps()
  end

  @required_fields ~w(version name category_weights)a
  @optional_fields ~w(description is_active is_draft normalization_method normalization_settings missing_data_strategies deployed_at)a

  def changeset(config, attrs) do
    config
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:normalization_method, @normalization_methods)
    |> validate_category_weights()
    |> validate_missing_data_strategies()
    |> validate_normalization_settings()
    |> unique_constraint(:version)
  end

  @doc """
  Changeset for activating a configuration (deploying it).
  """
  def activate_changeset(config) do
    config
    |> change(%{is_active: true, is_draft: false, deployed_at: DateTime.utc_now()})
  end

  @doc """
  Changeset for deactivating a configuration.
  """
  def deactivate_changeset(config) do
    config
    |> change(%{is_active: false})
  end

  defp validate_category_weights(changeset) do
    case get_field(changeset, :category_weights) do
      nil ->
        changeset

      weights when is_map(weights) ->
        total = weights |> Map.values() |> Enum.sum()

        cond do
          abs(total - 1.0) > 0.001 ->
            add_error(changeset, :category_weights, "must sum to 1.0 (currently #{total})")

          not Enum.all?(Map.keys(weights), &(&1 in @categories)) ->
            add_error(changeset, :category_weights, "contains invalid category keys")

          not Enum.all?(Map.values(weights), &(is_number(&1) and &1 >= 0 and &1 <= 1)) ->
            add_error(changeset, :category_weights, "all values must be between 0 and 1")

          true ->
            changeset
        end

      _ ->
        add_error(changeset, :category_weights, "must be a map")
    end
  end

  defp validate_missing_data_strategies(changeset) do
    case get_field(changeset, :missing_data_strategies) do
      nil ->
        changeset

      strategies when is_map(strategies) ->
        if Enum.all?(Map.values(strategies), &(&1 in @missing_data_strategies)) do
          changeset
        else
          add_error(
            changeset,
            :missing_data_strategies,
            "all values must be one of: #{Enum.join(@missing_data_strategies, ", ")}"
          )
        end

      _ ->
        changeset
    end
  end

  defp validate_normalization_settings(changeset) do
    method = get_field(changeset, :normalization_method)
    settings = get_field(changeset, :normalization_settings) || %{}

    case method do
      "bayesian" ->
        validate_bayesian_settings(changeset, settings)

      "zscore" ->
        validate_zscore_settings(changeset, settings)

      "percentile" ->
        changeset

      "none" ->
        changeset

      _ ->
        changeset
    end
  end

  defp validate_bayesian_settings(changeset, settings) do
    prior_mean = Map.get(settings, "prior_mean")
    min_votes = Map.get(settings, "min_votes")

    cond do
      prior_mean != nil and (prior_mean < 0 or prior_mean > 10) ->
        add_error(changeset, :normalization_settings, "prior_mean must be between 0 and 10")

      min_votes != nil and min_votes < 1 ->
        add_error(changeset, :normalization_settings, "min_votes must be at least 1")

      true ->
        changeset
    end
  end

  defp validate_zscore_settings(changeset, settings) do
    floor = Map.get(settings, "floor")
    ceiling = Map.get(settings, "ceiling")

    cond do
      floor != nil and ceiling != nil and floor >= ceiling ->
        add_error(changeset, :normalization_settings, "floor must be less than ceiling")

      true ->
        changeset
    end
  end

  @doc """
  Returns the list of valid categories.
  """
  def categories, do: @categories

  @doc """
  Returns the list of valid normalization methods.
  """
  def normalization_methods, do: @normalization_methods

  @doc """
  Returns the list of valid missing data strategies.
  """
  def missing_data_strategies, do: @missing_data_strategies

  @doc """
  Default configuration for initial setup.
  """
  def default_config do
    %{
      version: 1,
      name: "Default Balanced",
      description: "Initial balanced configuration with equal weights",
      is_active: true,
      is_draft: false,
      category_weights: %{
        "popular_opinion" => 0.20,
        "industry_recognition" => 0.20,
        "cultural_impact" => 0.20,
        "people_quality" => 0.20,
        "financial_performance" => 0.20
      },
      normalization_method: "none",
      missing_data_strategies: %{
        "popular_opinion" => "neutral",
        "industry_recognition" => "exclude",
        "cultural_impact" => "neutral",
        "people_quality" => "average",
        "financial_performance" => "exclude"
      }
    }
  end

  @doc """
  Recommended configuration based on analysis.
  """
  def recommended_config do
    %{
      version: 2,
      name: "Optimized v2",
      description: "Weights adjusted to reduce financial penalty and emphasize ratings",
      is_draft: true,
      category_weights: %{
        "popular_opinion" => 0.40,
        "industry_recognition" => 0.15,
        "cultural_impact" => 0.25,
        "people_quality" => 0.15,
        "financial_performance" => 0.05
      },
      normalization_method: "bayesian",
      normalization_settings: %{
        "prior_mean" => 6.5,
        "min_votes" => 500
      },
      missing_data_strategies: %{
        "popular_opinion" => "neutral",
        "industry_recognition" => "exclude",
        "cultural_impact" => "neutral",
        "people_quality" => "average",
        "financial_performance" => "exclude"
      }
    }
  end
end
