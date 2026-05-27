defmodule Cinegraph.Services.OMDb.ClientStub do
  @moduledoc """
  Test stub for `Cinegraph.Services.OMDb.Client`. Avoids live HTTP calls in
  unit tests. Configure a per-test response with `put_response/1` and restore
  with `reset/0` (or via `on_exit`).

  Usage:
      setup do
        Application.put_env(:cinegraph, :omdb_http_client, __MODULE__)
        on_exit(fn -> Application.delete_env(:cinegraph, :omdb_http_client) end)
        ClientStub.put_response({:ok, %{"Response" => "True", "Title" => "Stub Movie"}})
      end

  Matches the public API of `Cinegraph.Services.OMDb.Client`.
  """

  # Application env requires atom keys (Elixir 1.19+). Use a dedicated atom.
  @config_key :omdb_client_stub_response

  @doc "Set the response returned by `get_movie_by_imdb_id/2` for this test process."
  def put_response(response) do
    Application.put_env(:cinegraph, @config_key, response)
  end

  @doc "Clear the configured response."
  def reset do
    Application.delete_env(:cinegraph, @config_key)
  end

  @doc false
  def get_movie_by_imdb_id(_imdb_id, _opts \\ []) do
    Application.get_env(
      :cinegraph,
      @config_key,
      {:ok, %{"Response" => "True", "Title" => "Stub"}}
    )
  end

  @doc false
  def get_movie_by_title(_title, _opts \\ []) do
    {:error, "not implemented in stub"}
  end
end
