defmodule Cinegraph.Images.Providers.Unsplash do
  @moduledoc """
  Unsplash search provider for the festival admin "Suggest images" picker
  (#880 Phase 2).

  Hits `https://api.unsplash.com/search/photos`. Auth via `client_id` query
  param. Returns the canonical `result()` shape used by all stock providers.

  Returns `:disabled` when `UNSPLASH_ACCESS_KEY` is unset — the picker uses
  this to hide the Unsplash section without crashing.
  """

  @endpoint "https://api.unsplash.com/search/photos"

  @type result :: %{
          id: String.t(),
          thumb_url: String.t(),
          full_url: String.t(),
          attribution: %{name: String.t(), profile_url: String.t() | nil},
          source: :unsplash
        }

  @doc """
  Searches Unsplash for landscape photos and normalizes the response.

  Returns `:disabled` when `UNSPLASH_ACCESS_KEY` is blank.
  """
  @spec search(String.t(), pos_integer()) ::
          {:ok, [result()]} | {:error, term()} | :disabled
  def search(query, per_page \\ 6) when is_binary(query) and is_integer(per_page) do
    case access_key() do
      nil ->
        :disabled

      "" ->
        :disabled

      access_key ->
        params =
          URI.encode_query(%{
            "query" => query,
            "per_page" => per_page,
            "orientation" => "landscape",
            "client_id" => access_key
          })

        url = "#{@endpoint}?#{params}"

        case HTTPoison.get(url, [], recv_timeout: 5_000, timeout: 5_000) do
          {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
            with {:ok, json} <- Jason.decode(body),
                 results when is_list(results) <- Map.get(json, "results", []) do
              {:ok, Enum.map(results, &normalize/1)}
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

  defp access_key do
    Application.get_env(:cinegraph, __MODULE__, [])
    |> Keyword.get(:access_key)
  end

  defp normalize(%{} = photo) do
    urls = Map.get(photo, "urls", %{})
    user = Map.get(photo, "user", %{})

    %{
      id: Map.get(photo, "id"),
      thumb_url: Map.get(urls, "thumb") || Map.get(urls, "small"),
      full_url: Map.get(urls, "regular") || Map.get(urls, "full") || Map.get(urls, "raw"),
      attribution: %{
        name: Map.get(user, "name") || Map.get(user, "username") || "Unsplash",
        profile_url: get_in(user, ["links", "html"])
      },
      source: :unsplash
    }
  end
end
