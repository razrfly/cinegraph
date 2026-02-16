defmodule Cinegraph.Scrapers.Http.Adapter do
  @moduledoc """
  Behaviour for HTTP scraping adapters.

  Adapters implement a common interface for fetching web pages,
  allowing the scraping provider to be swapped without changing scraper logic.
  """

  @doc """
  Fetch a URL and return its HTML body.

  ## Options
  - `:mode` - Fetch mode (adapter-specific, e.g. `:javascript`, `:normal`)
  - `:timeout` - Request timeout in milliseconds
  - `:recv_timeout` - Receive timeout in milliseconds

  ## Returns
  - `{:ok, body}` - Success with HTML body
  - `{:ok, body, metadata}` - Success with HTML body and metadata map
  - `{:error, reason}` - Failure
  """
  @callback fetch(url :: String.t(), opts :: keyword()) ::
              {:ok, String.t()}
              | {:ok, String.t(), map()}
              | {:error, term()}

  @doc "Returns a string identifier for this adapter."
  @callback name() :: String.t()

  @doc "Returns true if this adapter is configured and ready to use."
  @callback available?() :: boolean()
end
