defmodule Mix.Tasks.Cinegraph.EnrichCollectionImagery do
  @moduledoc """
  One-shot enrichment for public collection imagery.

  Fetches Open Graph images for movie lists and festival organizations and stores
  remote image URLs only. Re-runnable; existing image fields are left untouched.
  """
  use Mix.Task

  import Ecto.Query

  alias Cinegraph.Festivals.FestivalOrganization
  alias Cinegraph.Movies.MovieList
  alias Cinegraph.Repo

  @shortdoc "Enriches movie list and awards imagery from source websites"
  @requirements ["app.start"]
  @headers [{"user-agent", "CinegraphBot/1.0 (+https://cinegraph.io)"}]

  @impl true
  def run(_args) do
    enrich_movie_lists()
    enrich_festival_organizations()
  end

  defp enrich_movie_lists do
    MovieList
    |> where([l], is_nil(l.cover_image_url) and not is_nil(l.source_url))
    |> Repo.all()
    |> Enum.each(fn list ->
      case fetch_og_image(list.source_url) do
        {:ok, image_url} ->
          list
          |> MovieList.changeset(%{cover_image_url: image_url})
          |> Repo.update()

          Mix.shell().info("movie_lists: #{list.source_key} -> #{image_url}")

        :error ->
          Mix.shell().info("movie_lists: #{list.source_key} missed")
      end
    end)
  end

  defp enrich_festival_organizations do
    FestivalOrganization
    |> where([o], is_nil(o.logo_url) and not is_nil(o.website))
    |> Repo.all()
    |> Enum.each(fn org ->
      case fetch_og_image(org.website) do
        {:ok, image_url} ->
          org
          |> FestivalOrganization.changeset(%{logo_url: image_url})
          |> Repo.update()

          Mix.shell().info("festival_organizations: #{org.slug || org.id} -> #{image_url}")

        :error ->
          Mix.shell().info("festival_organizations: #{org.slug || org.id} missed")
      end
    end)
  end

  defp fetch_og_image(nil), do: :error
  defp fetch_og_image(""), do: :error

  defp fetch_og_image(url) do
    case HTTPoison.get(url, @headers,
           follow_redirect: true,
           timeout: 10_000,
           recv_timeout: 10_000
         ) do
      {:ok, %{status_code: status, body: body}} when status in 200..299 ->
        body
        |> og_image_from_html()
        |> absolute_url(url)

      _ ->
        :error
    end
  end

  defp og_image_from_html(body) do
    patterns = [
      ~r/<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']/i,
      ~r/<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']/i,
      ~r/<meta[^>]+name=["']twitter:image["'][^>]+content=["']([^"']+)["']/i
    ]

    Enum.find_value(patterns, fn pattern ->
      case Regex.run(pattern, body) do
        [_, image] -> html_unescape(image)
        _ -> nil
      end
    end)
  end

  defp absolute_url(nil, _base), do: :error
  defp absolute_url("http" <> _ = url, _base), do: {:ok, url}

  defp absolute_url("/" <> _ = path, base) do
    uri = URI.parse(base)
    {:ok, "#{uri.scheme}://#{uri.host}#{path}"}
  end

  defp absolute_url(_url, _base), do: :error

  defp html_unescape(value) do
    value
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end
end
