defmodule CinegraphWeb.Resolvers.SearchResolver do
  @moduledoc """
  Resolvers for the unified `globalSearch` GraphQL query.
  """

  alias Cinegraph.Search

  @doc """
  Wraps `Cinegraph.Search.global/2` for GraphQL clients.

  The shaped map returned by the backend already matches the
  `:search_results` Absinthe type exactly, so this is a passthrough.
  """
  def global_search(_parent, args, _resolution) do
    query = Map.get(args, :q, "")
    limit = Map.get(args, :limit, 5)
    {:ok, Search.global(query, limit: limit)}
  end
end
