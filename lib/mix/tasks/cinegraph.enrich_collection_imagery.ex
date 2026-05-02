defmodule Mix.Tasks.Cinegraph.EnrichCollectionImagery do
  @moduledoc """
  One-shot enrichment for public collection imagery.

  Fetches Open Graph images for movie lists and festival organizations and stores
  remote image URLs only. Re-runnable; existing image fields are left untouched.
  """
  use Mix.Task

  import Bitwise
  import Ecto.Query

  alias Cinegraph.Festivals.FestivalOrganization
  alias Cinegraph.Movies.MovieList
  alias Cinegraph.Repo

  @shortdoc "Enriches movie list and awards imagery from source websites"
  @requirements ["app.start"]
  @headers [{"user-agent", "CinegraphBot/1.0 (+https://cinegraph.org)"}]
  @batch_size 100
  @max_redirects 5
  @og_image_patterns [
    ~r/<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']/i,
    ~r/<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']/i,
    ~r/<meta[^>]+name=["']twitter:image["'][^>]+content=["']([^"']+)["']/i
  ]

  @impl true
  def run(_args) do
    enrich_movie_lists()
    enrich_festival_organizations()
    :ok
  end

  defp enrich_movie_lists do
    query =
      MovieList
      |> where([l], is_nil(l.cover_image_url) and not is_nil(l.source_url))

    process_in_batches(query, fn list ->
      case fetch_og_image(list.source_url) do
        {:ok, image_url} ->
          case list
               |> MovieList.changeset(%{cover_image_url: image_url})
               |> Repo.update() do
            {:ok, _} ->
              Mix.shell().info("movie_lists: #{list.source_key} -> #{image_url}")

            {:error, changeset} ->
              Mix.shell().error(
                "movie_lists: #{list.source_key} failed: #{inspect(changeset.errors)}"
              )
          end

        :error ->
          Mix.shell().info("movie_lists: #{list.source_key} missed")
      end
    end)
  end

  defp enrich_festival_organizations do
    query =
      FestivalOrganization
      |> where([o], is_nil(o.logo_url) and not is_nil(o.website))

    process_in_batches(query, fn org ->
      case fetch_og_image(org.website) do
        {:ok, image_url} ->
          case org
               |> FestivalOrganization.changeset(%{logo_url: image_url})
               |> Repo.update() do
            {:ok, _} ->
              Mix.shell().info("festival_organizations: #{org.slug || org.id} -> #{image_url}")

            {:error, changeset} ->
              Mix.shell().error(
                "festival_organizations: #{org.slug || org.id} failed: #{inspect(changeset.errors)}"
              )
          end

        :error ->
          Mix.shell().info("festival_organizations: #{org.slug || org.id} missed")
      end
    end)
  end

  defp process_in_batches(query, fun, last_id \\ 0) do
    batch =
      query
      |> where([record], record.id > ^last_id)
      |> order_by([record], asc: record.id)
      |> limit(^@batch_size)
      |> Repo.all()

    case batch do
      [] ->
        :ok

      records ->
        Enum.each(records, fun)
        process_in_batches(query, fun, List.last(records).id)
    end
  end

  defp fetch_og_image(nil), do: :error
  defp fetch_og_image(""), do: :error

  defp fetch_og_image(url), do: fetch_og_image(url, 0)

  defp fetch_og_image(_url, redirects) when redirects > @max_redirects, do: :error

  defp fetch_og_image(url, redirects) do
    with {:ok, safe_url} <- validate_public_http_url(url) do
      case HTTPoison.get(safe_url, @headers,
             follow_redirect: false,
             timeout: 10_000,
             recv_timeout: 10_000
           ) do
        {:ok, %{status_code: status, headers: headers}} when status in 300..399 ->
          headers
          |> location_header()
          |> redirect_url(safe_url)
          |> fetch_og_image(redirects + 1)

        {:ok, %{status_code: status, body: body}} when status in 200..299 ->
          body
          |> og_image_from_html()
          |> absolute_url(safe_url)

        _ ->
          :error
      end
    else
      :error -> :error
    end
  end

  defp og_image_from_html(body) do
    Enum.find_value(@og_image_patterns, fn pattern ->
      case Regex.run(pattern, body) do
        [_, image] -> html_unescape(image)
        _ -> nil
      end
    end)
  end

  defp absolute_url(nil, _base), do: :error

  defp absolute_url(url, base) when is_binary(url) do
    merged = URI.merge(base, url)

    case merged do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and not is_nil(host) ->
        {:ok, URI.to_string(uri)}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp absolute_url(_url, _base), do: :error

  defp location_header(headers) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == "location", do: value
    end)
  end

  defp redirect_url(nil, _base), do: :error

  defp redirect_url(location, base) do
    base
    |> URI.merge(location)
    |> URI.to_string()
  rescue
    _ -> :error
  end

  defp validate_public_http_url(:error), do: :error

  defp validate_public_http_url(url) when is_binary(url) do
    uri = URI.parse(url)

    with %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) <-
           uri,
         :ok <- validate_public_host(host) do
      {:ok, URI.to_string(uri)}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp validate_public_http_url(_url), do: :error

  defp validate_public_host(host) do
    addresses =
      host
      |> String.to_charlist()
      |> resolve_addresses()

    if addresses != [] and Enum.all?(addresses, &public_ip?/1), do: :ok, else: :error
  end

  defp resolve_addresses(host) do
    [:inet, :inet6]
    |> Enum.flat_map(fn family ->
      case :inet.getaddrs(host, family) do
        {:ok, addresses} -> addresses
        _ -> []
      end
    end)
  end

  defp public_ip?({a, b, _c, _d}) do
    cond do
      a in [0, 10, 127] -> false
      a == 100 and b in 64..127 -> false
      a == 169 and b == 254 -> false
      a == 172 and b in 16..31 -> false
      a == 192 and b in [0, 168] -> false
      a == 198 and b in [18, 19, 51] -> false
      a == 203 and b == 0 -> false
      a >= 224 -> false
      true -> true
    end
  end

  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  defp public_ip?({a, _b, _c, _d, _e, _f, _g, _h}) when (a &&& 0xFE00) == 0xFC00, do: false
  defp public_ip?({a, _b, _c, _d, _e, _f, _g, _h}) when (a &&& 0xFFC0) == 0xFE80, do: false
  defp public_ip?({0x2001, 0x0DB8, _c, _d, _e, _f, _g, _h}), do: false
  defp public_ip?({_a, _b, _c, _d, _e, _f, _g, _h}), do: true

  defp html_unescape(value) do
    value
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end
end
