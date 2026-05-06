defmodule Cinegraph.Images.Providers.Pixabay do
  @moduledoc """
  Pixabay search provider for the festival admin "Suggest images" picker
  (#880 Phase 2).

  Hits `https://pixabay.com/api/`. Auth via `key=` query param. Returns the
  canonical `result()` shape; `:disabled` when `PIXABAY_API_KEY` is unset.

  Pixabay requires API credentials in the `key` query parameter. Keep `key`
  covered by Phoenix parameter filtering and avoid logging outbound request
  URLs from this module.
  """

  @endpoint "https://pixabay.com/api/"

  @type result :: Cinegraph.Images.Providers.Unsplash.result()

  @doc """
  Searches Pixabay for horizontal photos and normalizes the response.

  Returns `:disabled` when `PIXABAY_API_KEY` is blank. Pixabay requires the API
  key in the request query string, so callers must not log the generated URL.
  """
  @spec search(String.t(), pos_integer()) ::
          {:ok, [result()]} | {:error, term()} | :disabled
  def search(query, per_page \\ 6) when is_binary(query) and is_integer(per_page) do
    case api_key() do
      nil ->
        :disabled

      "" ->
        :disabled

      api_key ->
        # Pixabay's `per_page` minimum is 3.
        per_page = max(per_page, 3)

        params =
          URI.encode_query(%{
            "key" => api_key,
            "q" => query,
            "per_page" => per_page,
            "image_type" => "photo",
            "safesearch" => "true",
            "orientation" => "horizontal"
          })

        url = "#{@endpoint}?#{params}"

        case HTTPoison.get(url, [], recv_timeout: 5_000, timeout: 5_000) do
          {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
            with {:ok, json} <- Jason.decode(body),
                 hits when is_list(hits) <- Map.get(json, "hits", []) do
              {:ok, Enum.map(hits, &normalize/1)}
            else
              _ -> {:error, :decode_failed}
            end

          {:ok, %HTTPoison.Response{status_code: 429}} ->
            {:error, :rate_limited}

          {:ok, %HTTPoison.Response{status_code: code}} ->
            {:error, {:http, code}}

          {:error, %HTTPoison.Error{reason: reason}} ->
            {:error, reason}
        end
    end
  end

  defp api_key do
    Application.get_env(:cinegraph, __MODULE__, [])
    |> Keyword.get(:api_key)
  end

  defp normalize(%{} = hit) do
    %{
      id: hit |> Map.get("id") |> to_string(),
      thumb_url: Map.get(hit, "previewURL") || Map.get(hit, "webformatURL"),
      full_url: Map.get(hit, "largeImageURL") || Map.get(hit, "webformatURL"),
      attribution: %{
        name: Map.get(hit, "user") || "Pixabay",
        profile_url: Map.get(hit, "pageURL")
      },
      source: :pixabay
    }
  end
end
