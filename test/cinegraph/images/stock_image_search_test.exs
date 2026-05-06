defmodule Cinegraph.Images.StockImageSearchTest do
  use ExUnit.Case, async: false

  alias Cinegraph.Images.StockImageSearch

  alias Cinegraph.Images.Providers.{Unsplash, Pexels, Pixabay}

  setup do
    # Snapshot config; restore after each test so we don't leak state.
    saved = %{
      unsplash: Application.get_env(:cinegraph, Unsplash),
      pexels: Application.get_env(:cinegraph, Pexels),
      pixabay: Application.get_env(:cinegraph, Pixabay)
    }

    on_exit(fn ->
      Application.put_env(:cinegraph, Unsplash, saved.unsplash || [])
      Application.put_env(:cinegraph, Pexels, saved.pexels || [])
      Application.put_env(:cinegraph, Pixabay, saved.pixabay || [])
    end)

    :ok
  end

  describe "search/2 with no keys configured" do
    setup do
      Application.put_env(:cinegraph, Unsplash, access_key: "")
      Application.put_env(:cinegraph, Pexels, api_key: "")
      Application.put_env(:cinegraph, Pixabay, api_key: "")
      :ok
    end

    test "returns :disabled for every provider" do
      result = StockImageSearch.search("cannes")

      assert %{unsplash: :disabled, pexels: :disabled, pixabay: :disabled} = result
    end
  end

  describe "providers/0" do
    test "lists the three providers in display order" do
      assert StockImageSearch.providers() == [:unsplash, :pexels, :pixabay]
    end
  end

  describe "provider :disabled handling" do
    test "Unsplash returns :disabled when access_key is nil" do
      Application.put_env(:cinegraph, Unsplash, access_key: nil)
      assert Unsplash.search("cannes") == :disabled
    end

    test "Unsplash returns :disabled when access_key is empty string" do
      Application.put_env(:cinegraph, Unsplash, access_key: "")
      assert Unsplash.search("cannes") == :disabled
    end

    test "Pexels returns :disabled when api_key is empty" do
      Application.put_env(:cinegraph, Pexels, api_key: "")
      assert Pexels.search("cannes") == :disabled
    end

    test "Pixabay returns :disabled when api_key is empty" do
      Application.put_env(:cinegraph, Pixabay, api_key: "")
      assert Pixabay.search("cannes") == :disabled
    end
  end
end
