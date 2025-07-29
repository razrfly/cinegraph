defmodule Cinegraph.ApiProcessors.Behaviour do
  @moduledoc """
  Behaviour for API processors that fetch and store movie data from external sources.
  
  Each API processor must implement these callbacks to ensure consistent
  integration with the movie import system and Oban job processing.
  """
  
  alias Cinegraph.Movies.Movie
  
  @doc """
  Process a movie by fetching data from the external API and storing it.
  
  ## Parameters
    - movie_id: The internal database ID of the movie
    - opts: Keyword list of options specific to each processor
  
  ## Returns
    - {:ok, movie} - Successfully processed and updated movie
    - {:error, reason} - Processing failed with reason
  """
  @callback process_movie(movie_id :: integer(), opts :: keyword()) :: 
    {:ok, Movie.t()} | {:error, term()}
  
  @doc """
  Check if a movie can be processed by this API.
  
  Usually checks if the required identifier (e.g., tmdb_id, imdb_id) is present.
  
  ## Parameters
    - movie: The movie struct to check
  
  ## Returns
    - true if the movie can be processed
    - false otherwise
  """
  @callback can_process?(movie :: Movie.t()) :: boolean()
  
  @doc """
  Returns the identifier field required by this API.
  
  ## Returns
    - Atom representing the field name (e.g., :tmdb_id, :imdb_id)
  """
  @callback required_identifier() :: atom()
  
  @doc """
  Returns the name of this API processor.
  
  ## Returns
    - String name of the API (e.g., "TMDb", "OMDb")
  """
  @callback name() :: String.t()
  
  @doc """
  Returns the field where the raw API response is stored.
  
  ## Returns
    - Atom representing the field name (e.g., :tmdb_data, :omdb_data)
  """
  @callback data_field() :: atom()
  
  @doc """
  Checks if the movie already has data from this API.
  
  ## Parameters
    - movie: The movie struct to check
  
  ## Returns
    - true if data exists
    - false otherwise
  """
  @callback has_data?(movie :: Movie.t()) :: boolean()
  
  @doc """
  Returns rate limit delay in milliseconds for this API.
  
  ## Returns
    - Integer representing milliseconds to wait between requests
  """
  @callback rate_limit_ms() :: non_neg_integer()
  
  @doc """
  Optional callback to validate API configuration.
  
  ## Returns
    - :ok if configuration is valid
    - {:error, reason} if configuration is invalid
  """
  @callback validate_config() :: :ok | {:error, term()}
  
  @optional_callbacks [validate_config: 0]
end