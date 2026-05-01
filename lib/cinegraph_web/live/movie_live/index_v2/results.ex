defmodule CinegraphWeb.MovieLive.IndexV2.Results do
  @moduledoc """
  Shared result preparation for the V2 movie discovery body.
  """

  alias Cinegraph.Repo

  # Preloads only what the V2 grid needs. Empty list = use the read replica.
  # `:score_cache` is preloaded only when a Lens sort is active so cards can
  # surface lens-component chips consistently on every scoped discovery page.
  def preload_card_assocs([], _active_lens_key), do: []

  def preload_card_assocs(movies, active_lens_key)
      when is_binary(active_lens_key) and active_lens_key != "" do
    Repo.replica().preload(movies, [:score_cache])
  end

  def preload_card_assocs(movies, _active_lens_key), do: movies
end
