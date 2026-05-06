defmodule Cinegraph.Images.Providers.Pexels do
  @moduledoc """
  Pexels search provider for the festival admin "Suggest images" picker
  (#880 Phase 2).

  Hits `https://api.pexels.com/v1/search`. Auth via `Authorization` header.
  Returns the canonical `result()` shape; `:disabled` when `PEXELS_API_KEY`
  is unset.
  """

  @endpoint "https://api.pexels.com/v1/search"

  @type result :: Cinegraph.Images.Providers.Unsplash.result()

  @spec search(String.t(), pos_integer()) ::
          {:ok, [result()]} | {:error, term()} | :disabled
  def search(query, per_page \\ 6) when is_binary(query) and is_integer(per_page) do
    case api_key() do
      nil ->
        :disabled

      "" ->
        :disabled

      api_key ->
        params = URI.encode_query(%{"query" => query, "per_page" => per_page})
        url = "#{@endpoint}?#{params}"
        headers = [{"Authorization", api_key}]

        case HTTPoison.get(url, headers, recv_timeout: 5_000, timeout: 5_000) do
          {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
            with {:ok, json} <- Jason.decode(body),
                 photos when is_list(photos) <- Map.get(json, "photos", []) do
              {:ok, Enum.map(photos, &normalize/1)}
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

  defp normalize(%{} = photo) do
    src = Map.get(photo, "src", %{})

    %{
      id: photo |> Map.get("id") |> to_string(),
      thumb_url: Map.get(src, "tiny") || Map.get(src, "small") || Map.get(src, "medium"),
      full_url: Map.get(src, "large") || Map.get(src, "large2x") || Map.get(src, "original"),
      attribution: %{
        name: Map.get(photo, "photographer") || "Pexels",
        profile_url: Map.get(photo, "photographer_url")
      },
      source: :pexels
    }
  end
end
