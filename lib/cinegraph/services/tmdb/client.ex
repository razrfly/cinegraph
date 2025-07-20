defmodule Cinegraph.Services.TMDb.Client do
  @moduledoc """
  HTTP client for TMDb API with rate limiting and error handling.
  """

  @base_url "https://api.themoviedb.org/3"
  @timeout 30_000

  def get(endpoint, params \\ %{}) do
    api_key = get_api_key()
    
    params = Map.put(params, :api_key, api_key)
    query_string = build_query_string(params)
    url = build_url(endpoint) <> query_string
    
    headers = [
      {"Accept", "application/json"},
      {"Content-Type", "application/json"}
    ]

    request = Finch.build(:get, url, headers, nil)
    
    case Finch.request(request, Cinegraph.Finch, receive_timeout: @timeout) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        Jason.decode(body)
        
      {:ok, %Finch.Response{status: 429, headers: headers}} ->
        retry_after = get_retry_after(headers)
        {:error, {:rate_limited, retry_after}}
        
      {:ok, %Finch.Response{status: 401}} ->
        {:error, :unauthorized}
        
      {:ok, %Finch.Response{status: 404}} ->
        {:error, :not_found}
        
      {:ok, %Finch.Response{status: status, body: body}} when status >= 500 ->
        {:error, {:server_error, status, body}}
        
      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}
        
      {:error, reason} ->
        {:error, {:network_error, reason}}
    end
  end

  defp get_api_key do
    Application.get_env(:cinegraph, __MODULE__)[:api_key] ||
      raise "TMDb API key not configured. Set TMDB_API_KEY environment variable."
  end

  defp build_url(endpoint) do
    Path.join(@base_url, endpoint)
  end

  defp get_retry_after(headers) do
    case List.keyfind(headers, "retry-after", 0) do
      {"retry-after", value} -> String.to_integer(value)
      nil -> 60  # Default to 60 seconds
    end
  end

  def build_query_string(params) when params == %{}, do: ""
  
  def build_query_string(params) do
    params
    |> Enum.map(fn {k, v} -> "#{k}=#{URI.encode(to_string(v))}" end)
    |> Enum.join("&")
    |> then(&"?#{&1}")
  end
end