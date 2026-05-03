defmodule Cinegraph.Scrapers.Http.BodyDiagnostics do
  @moduledoc """
  Lightweight HTML body diagnostics for scraper responses.
  """

  @doc """
  Return JSON-safe diagnostics for an HTML body.
  """
  def diagnostics(url, body, opts \\ []) when is_binary(body) do
    title = html_title(body)
    title_link_count = count(body, ~r/\/title\/tt\d+/)
    ipc_item_count = count(body, ~r/ipc-metadata-list-summary-item/)
    lister_item_count = count(body, ~r/lister-item/)
    pc_status = Keyword.get(opts, :pc_status)

    %{
      body_bytes: byte_size(body),
      title: title,
      html_title: title,
      title_link_count: title_link_count,
      ipc_item_count: ipc_item_count,
      lister_item_count: lister_item_count,
      pc_status: pc_status,
      body_classification: classify(url, body, title, title_link_count, pc_status)
    }
  end

  @doc """
  Return blocked/non-list scraper diagnostics, or `{:ok, diagnostics}` when accepted.
  """
  def blocked_error(url, body, opts \\ []) when is_binary(body) do
    diagnostics = diagnostics(url, body, opts)

    case diagnostics.body_classification do
      "blocked_403" -> {:blocked, :forbidden, diagnostics}
      "blocked_challenge" -> {:blocked, :challenge, diagnostics}
      "origin_error" -> {:blocked, :origin_error, diagnostics}
      "imdb_non_list_html" -> {:blocked, :non_list_html, diagnostics}
      _ -> {:ok, diagnostics}
    end
  end

  @doc """
  Return whether a URL points at an IMDb list page.
  """
  def imdb_list_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host, path: path} when is_binary(host) and is_binary(path) ->
        String.ends_with?(host, "imdb.com") and Regex.match?(~r|/list/ls\d+/?|, path)

      _ ->
        false
    end
  end

  defp classify(url, body, title, title_link_count, pc_status) do
    downcased_body = String.downcase(body)
    downcased_title = title |> to_string() |> String.downcase()

    cond do
      String.contains?(downcased_body, "403 forbidden") or
          String.contains?(downcased_title, "403 forbidden") ->
        "blocked_403"

      String.contains?(downcased_body, "captcha") or
        String.contains?(downcased_body, "access denied") or
        String.contains?(downcased_body, "robot check") or
          String.contains?(downcased_body, "unusual traffic") ->
        "blocked_challenge"

      is_integer(pc_status) and pc_status >= 400 ->
        "origin_error"

      imdb_list_url?(url) and title_link_count == 0 ->
        "imdb_non_list_html"

      title_link_count > 0 ->
        "imdb_list_html"

      byte_size(body) < 500 ->
        "tiny_html"

      true ->
        "unknown_html"
    end
  end

  defp html_title(body) do
    case Regex.run(~r/<title[^>]*>([\s\S]*?)<\/title>/i, body) do
      [_, title] ->
        title
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      _ ->
        nil
    end
  end

  defp count(body, regex), do: regex |> Regex.scan(body) |> length()
end
