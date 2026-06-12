defmodule Cinegraph.Workers.SurfaceAreaCacheWarmerTest do
  @moduledoc "#1108 §10c — warms SurfaceArea.report into :health_cache."
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Workers.SurfaceAreaCacheWarmer

  setup do
    Cachex.clear(:health_cache)
    :ok
  end

  test "warms the surface-area report into :health_cache" do
    assert {:ok, %{sources: n}} = SurfaceAreaCacheWarmer.perform(%Oban.Job{args: %{}})
    assert n > 0
    assert {:ok, cached} = Cachex.get(:health_cache, "surface_area:report")
    assert is_map(cached) and is_list(cached.sources)
  end
end
