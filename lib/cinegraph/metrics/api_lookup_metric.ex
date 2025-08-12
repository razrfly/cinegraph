defmodule Cinegraph.Metrics.ApiLookupMetric do
  @moduledoc """
  Schema for tracking all external API and scraping operations.
  Provides visibility into success rates, response times, and errors
  across TMDb, OMDb, IMDb scraping, and festival data sources.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "api_lookup_metrics" do
    field :source, :string         # "tmdb", "omdb", "imdb_scraper", "venice_scraper", etc.
    field :operation, :string      # "find_by_imdb", "search_movie", "fetch_ceremony", etc.
    field :target_identifier, :string  # IMDb ID, movie title, festival year, etc.
    field :success, :boolean
    field :confidence_score, :float    # For fuzzy matches (1.0 to 0.5 scale)
    field :fallback_level, :integer    # Which strategy succeeded (1-5)
    field :response_time_ms, :integer
    field :error_type, :string         # "not_found", "rate_limit", "timeout", "parse_error"
    field :error_message, :string
    field :metadata, :map              # Additional context

    timestamps()
  end

  @required_fields [:source, :operation, :success]
  @optional_fields [:target_identifier, :confidence_score, :fallback_level, 
                    :response_time_ms, :error_type, :error_message, :metadata]

  @doc false
  def changeset(metric, attrs) do
    metric
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:source, valid_sources())
    |> validate_number(:confidence_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:fallback_level, greater_than_or_equal_to: 1, less_than_or_equal_to: 6)
    |> validate_number(:response_time_ms, greater_than_or_equal_to: 0)
  end

  @doc """
  Returns list of valid source identifiers.
  """
  def valid_sources do
    ~w(tmdb omdb imdb_scraper venice_scraper cannes_scraper berlin_scraper 
       oscar_scraper canonical_scraper festival_scraper)
  end

  @doc """
  Returns list of common error types.
  """
  def error_types do
    ~w(not_found rate_limit timeout parse_error auth_error network_error invalid_response)
  end
end