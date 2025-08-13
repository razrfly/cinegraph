defmodule Cinegraph.Metrics.MetricDefinition do
  @moduledoc """
  Schema for metric definitions that describe how to interpret and normalize different metrics.
  
  This schema defines metadata about metrics from various sources (external APIs, festival 
  nominations, canonical lists) and maps them to categories with proper normalization.
  """
  
  use Ecto.Schema
  import Ecto.Changeset
  
  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id
  
  schema "metric_definitions" do
    field :code, :string
    field :name, :string
    field :description, :string
    
    # Source information
    field :source_table, :string
    field :source_type, :string
    field :source_field, :string
    
    # Category mapping
    field :category, :string  # 'ratings', 'awards', 'financial', 'cultural'
    field :subcategory, :string  # e.g., 'critic_rating', 'audience_rating', 'major_award'
    
    # Normalization
    field :normalization_type, :string  # 'linear', 'logarithmic', 'sigmoid', 'boolean', 'custom'
    field :normalization_params, :map
    field :raw_scale_min, :float
    field :raw_scale_max, :float
    
    # Display information
    field :display_format, :string  # 'percentage', 'score', 'money', 'count', 'boolean'
    field :display_unit, :string  # '%', '/10', '/100', '$', null
    
    # Metadata
    field :source_reliability, :float, default: 1.0
    field :active, :boolean, default: true
    
    timestamps()
  end
  
  @required_fields [:code, :name, :source_table, :category, :normalization_type]
  @optional_fields [:description, :source_type, :source_field, :subcategory, :normalization_params, 
                    :raw_scale_min, :raw_scale_max, :display_format, :display_unit,
                    :source_reliability, :active]
  
  @doc false
  def changeset(metric_definition, attrs) do
    metric_definition
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:code)
    |> validate_inclusion(:category, ["ratings", "awards", "financial", "cultural"])
    |> validate_inclusion(:normalization_type, ["linear", "logarithmic", "sigmoid", "boolean", "custom"])
    |> validate_inclusion(:display_format, ["percentage", "score", "money", "count", "boolean"], allow_nil: true)
  end
end