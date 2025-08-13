defmodule Cinegraph.Metrics.ApiLookupMetric do
  @moduledoc """
  Schema for tracking all external API and scraping operations.
  Provides visibility into success rates, response times, and errors
  across TMDb, OMDb, IMDb scraping, and festival data sources.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @min_fallback_level 1
  @max_fallback_level 6

  schema "api_lookup_metrics" do
    # "tmdb", "omdb", "imdb_scraper", "venice_scraper", etc.
    field :source, :string
    # "find_by_imdb", "search_movie", "fetch_ceremony", etc.
    field :operation, :string
    # IMDb ID, movie title, festival year, etc.
    field :target_identifier, :string
    field :success, :boolean
    # For fuzzy matches (0.0 to 1.0 scale, higher is better)
    field :confidence_score, :float
    # Which strategy succeeded (@min_fallback_level..@max_fallback_level)
    field :fallback_level, :integer
    field :response_time_ms, :integer
    # "not_found", "rate_limit", "timeout", "parse_error"
    field :error_type, :string
    field :error_message, :string
    # Additional context
    field :metadata, :map

    timestamps()
  end

  @required_fields [:source, :operation, :success]
  @optional_fields [
    :target_identifier,
    :confidence_score,
    :fallback_level,
    :response_time_ms,
    :error_type,
    :error_message,
    :metadata
  ]

  @doc false
  def changeset(metric, attrs) do
    metric
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:source, valid_sources())
    |> validate_number(:confidence_score,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> validate_inclusion(:error_type, error_types(), allow_nil: true)
    |> validate_number(:fallback_level,
      greater_than_or_equal_to: @min_fallback_level,
      less_than_or_equal_to: @max_fallback_level
    )
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
    ~w(
      not_found
      rate_limit
      timeout
      parse_error
      auth_error
      network_error
      invalid_response
      api_error
      error
      unknown
    )
  end
end
