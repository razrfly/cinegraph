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
    Repo.replica().preload(movies, [:score_cache, :scoreability])
  end

  def preload_card_assocs(movies, _active_lens_key),
    do: Repo.replica().preload(movies, [:scoreability])

  @doc """
  Batch-fetches the best available content cert for each movie (OMDb MPAA first,
  then TMDb US) and stamps it onto the virtual `cert_label` field.
  One query for the whole page — called only when `max_age` filter is active.
  """
  def preload_cert_labels([]), do: []

  def preload_cert_labels(movies) do
    ids = Enum.map(movies, & &1.id)

    %{rows: rows} =
      Repo.replica().query!(
        """
        SELECT m.id,
          COALESCE(
            (SELECT text_value FROM external_metrics
             WHERE movie_id = m.id AND source = 'omdb' AND metric_type = 'content_rating'
               AND text_value IS NOT NULL AND btrim(text_value) != ''
             ORDER BY fetched_at DESC
             LIMIT 1),
            (SELECT certification FROM movie_release_dates
             WHERE movie_id = m.id AND country_code = 'US'
               AND certification IS NOT NULL AND certification != ''
             ORDER BY release_type ASC LIMIT 1)
          ) AS cert
        FROM movies m
        WHERE m.id = ANY($1::int[])
        """,
        [ids]
      )

    cert_map = Map.new(rows, fn [id, cert] -> {id, cert} end)
    Enum.map(movies, fn m -> %{m | cert_label: cert_map[m.id]} end)
  end
end
