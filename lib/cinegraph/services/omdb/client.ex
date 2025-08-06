defmodule Cinegraph.Services.OMDb.Client do
  @moduledoc """
  Client for interacting with the OMDb API.
  Handles rate limiting and response parsing.
  """

  require Logger

  @base_url "http://www.omdbapi.com/"
  @timeout 30_000

  def get_movie_by_imdb_id(imdb_id, opts \\ []) do
    params = build_params(imdb_id: imdb_id, opts: opts)

    case make_request(params) do
      {:ok, %{"Response" => "True"} = data} ->
        {:ok, data}

      {:ok, %{"Response" => "False", "Error" => error}} ->
        {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_movie_by_title(title, opts \\ []) do
    params = build_params(title: title, opts: opts)

    case make_request(params) do
      {:ok, %{"Response" => "True"} = data} ->
        {:ok, data}

      {:ok, %{"Response" => "False", "Error" => error}} ->
        {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_params(imdb_id: imdb_id, opts: opts) do
    base_params(opts)
    |> Map.put("i", imdb_id)
  end

  defp build_params(title: title, opts: opts) do
    params =
      base_params(opts)
      |> Map.put("t", title)

    if year = opts[:year] do
      Map.put(params, "y", to_string(year))
    else
      params
    end
  end

  defp base_params(opts) do
    %{
      "apikey" => api_key(),
      "plot" => "short",
      "r" => "json"
    }
    |> maybe_add_tomatoes(opts[:tomatoes])
  end

  defp maybe_add_tomatoes(params, true), do: Map.put(params, "tomatoes", "true")
  defp maybe_add_tomatoes(params, _), do: params

  defp make_request(params) do
    url = build_url(params)

    Logger.debug("OMDb API request: #{url}")

    case HTTPoison.get(url, [], timeout: @timeout, recv_timeout: @timeout) do
      {:ok, %{status_code: 200, body: body}} ->
        Jason.decode(body)

      {:ok, %{status_code: status_code}} ->
        {:error, "HTTP #{status_code}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}
    end
  end

  defp build_url(params) do
    query_string = URI.encode_query(params)
    "#{@base_url}?#{query_string}"
  end

  defp api_key do
    Application.get_env(:cinegraph, __MODULE__)[:api_key] ||
      raise "OMDB_API_KEY not configured"
  end
end
