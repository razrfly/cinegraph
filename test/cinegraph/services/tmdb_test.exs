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

    test "fetches and caches company images on cache miss" do
      images = %{"logos" => [%{"file_path" => "/fresh.svg"}]}
      parent = self()

      assert {:ok, ^images} =
               TMDb.get_company_images(41_078,
                 track: false,
                 fetcher: fn "/company/41078/images" ->
                   send(parent, :fetched_company_images)
                   {:ok, images}
                 end
               )

      assert_received :fetched_company_images
      assert {:ok, ^images} = Cachex.get(:movies_cache, "tmdb:company_images:41078")
    end

    test "force_refresh bypasses cached company images and replaces the cache" do
      stale_images = %{"logos" => [%{"file_path" => "/stale.svg"}]}
      fresh_images = %{"logos" => [%{"file_path" => "/fresh.svg"}]}
      Cachex.put!(:movies_cache, "tmdb:company_images:41079", stale_images)

      assert {:ok, ^fresh_images} =
               TMDb.get_company_images(41_079,
                 force_refresh: true,
                 track: false,
                 fetcher: fn "/company/41079/images" -> {:ok, fresh_images} end
               )

      assert {:ok, ^fresh_images} = Cachex.get(:movies_cache, "tmdb:company_images:41079")
    end
  end
end
