defmodule Cinegraph.Scrapers.FestivalHttpStub do
  @moduledoc """
  ETS-backed HTTP stub for UnifiedFestivalScraper tests.

  Configured globally in `config/test.exs` as
  `config :cinegraph, :festival_http_client, Cinegraph.Scrapers.FestivalHttpStub`.
  Tests reset between cases via `reset!/0` in `setup`.

  Usage:

      FestivalHttpStub.set_response("/2018/", {:ok, "<html>...</html>"})
      FestivalHttpStub.set_response("/2026/", {:error, :forbidden})
      FestivalHttpStub.reset!()

  URL matching is substring-based: the longest registered key that `String.contains?`
  the requested URL wins (most-specific match, deterministic regardless of ETS hash order).
  """

  @table :festival_http_stub

  @doc "Initialize the ETS table. Called once from test_helper.exs."
  def start! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set])
        reset!()

      _ ->
        :ok
    end
  end

  @doc "Register a response for URLs containing `url_contains`."
  def set_response(url_contains, response) do
    :ets.insert(@table, {url_contains, response})
  end

  @doc "Clear all registered responses."
  def reset! do
    :ets.delete_all_objects(@table)
  end

  @doc "Implements the same interface as `Cinegraph.Scrapers.Http.Client.fetch/2`."
  def fetch(url, _mode) do
    :ets.tab2list(@table)
    |> Enum.sort_by(fn {key, _} -> -byte_size(key) end)
    |> Enum.find(fn {key, _} -> String.contains?(url, key) end)
    |> case do
      {_key, response} -> response
      nil -> {:error, :stub_no_match}
    end
  end
end
