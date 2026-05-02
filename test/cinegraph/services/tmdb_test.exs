defmodule Cinegraph.Services.TMDbTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Services.TMDb

  setup do
    Cachex.clear(:movies_cache)
    :ok
  end

  describe "get_company_images/2" do
    test "returns cached company images without calling the fetcher" do
      images = %{"logos" => [%{"file_path" => "/logo.svg"}]}
      Cachex.put!(:movies_cache, "tmdb:company_images:41077", images)

      assert {:ok, ^images} =
               TMDb.get_company_images(41_077, fn _path ->
                 flunk("cached company images should not call TMDb")
               end)
    end
  end
end
