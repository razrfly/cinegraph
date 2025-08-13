defmodule Cinegraph.Metrics.MetricDefinition do
  @moduledoc """
  Schema for metric definitions - the registry of all available metrics.
  Each metric has normalization rules and is mapped to a CRI dimension.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "metric_definitions" do
    field :code, :string
    field :name, :string
    field :category, :string
    field :cri_dimension, :string
    field :data_type, :string
    field :source, :string
    
    # Raw value information
    field :raw_scale_min, :float
    field :raw_scale_max, :float
    field :raw_unit, :string
    
    # Normalization configuration
    field :normalization_type, :string
    field :normalization_params, :map, default: %{}
    field :source_reliability, :float, default: 0.8
    
    field :active, :boolean, default: true
    
    timestamps()
  end

  @required_fields ~w(code name category cri_dimension data_type source normalization_type)a
  @optional_fields ~w(raw_scale_min raw_scale_max raw_unit normalization_params source_reliability active)a
  
  @categories ~w(rating award financial cultural popularity)
  @cri_dimensions ~w(timelessness cultural_penetration artistic_impact institutional public)
  @data_types ~w(numeric boolean categorical rank)
  @normalization_types ~w(linear logarithmic sigmoid boolean custom)

  def changeset(metric_definition, attrs) do
    metric_definition
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:cri_dimension, @cri_dimensions)
    |> validate_inclusion(:data_type, @data_types)
    |> validate_inclusion(:normalization_type, @normalization_types)
    |> validate_number(:source_reliability, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> unique_constraint(:code)
  end

  def categories, do: @categories
  def cri_dimensions, do: @cri_dimensions
  def data_types, do: @data_types
  def normalization_types, do: @normalization_types
end