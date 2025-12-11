defmodule Cinegraph.Sitemap do
  @moduledoc """
  Generates XML sitemaps for the Cinegraph website.
  Uses Sitemapper to generate sitemaps for movies, people, lists, and awards.

  ## URL Types
  - Static pages (/, /movies, /people, /lists, /awards)
  - Movies (/movies/:slug)
  - People (/people/:slug)
  - Lists (/lists/:slug)
  - Awards (/awards/:slug)

  ## Usage
  The sitemap is generated daily by an Oban worker and stored in priv/static/sitemaps.
  Files are served from /sitemaps/* routes.
  """

  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Movies.Person
  alias Cinegraph.Lists.ListSlugs
  alias Cinegraph.Festivals.FestivalOrganization
  import Ecto.Query
  require Logger

  @site_url "https://cinegraph.io"

  @doc """
  Generates and persists a sitemap for the website.
  Uses Repo.transaction with :infinity timeout for long-running sitemap generation.

  ## Options
  * `:environment` - Override environment detection (e.g., :prod, :dev)
  * `:host` - Override host for URL generation

  Returns :ok on success or {:error, reason} on failure.
  """
  def generate_and_persist(opts \\ []) do
    try do
      config = get_sitemap_config(opts)
      Logger.info("Starting sitemap generation for Cinegraph")

      # Use a database transaction to ensure proper streaming
      Repo.transaction(
        fn ->
          stream_urls(opts)
          |> tap(fn _ -> Logger.info("Starting sitemap generation with all URLs") end)
          |> Sitemapper.generate(config)
          |> tap(fn _ -> Logger.info("Sitemap generated, starting persistence") end)
          |> Sitemapper.persist(config)
          |> tap(fn _ -> Logger.info("Completed sitemap persistence") end)
          |> Stream.run()
        end,
        timeout: :infinity
      )

      Logger.info("Sitemap generation completed successfully")
      :ok
    rescue
      error ->
        Logger.error("Sitemap generation failed: #{inspect(error, pretty: true)}")
        Logger.error("Stacktrace: #{Exception.format_stacktrace()}")
        {:error, error}
    catch
      kind, reason ->
        Logger.error("Caught #{kind} in sitemap generation: #{inspect(reason, pretty: true)}")
        {:error, reason}
    end
  end

  @doc """
  Creates a stream of all URLs for the sitemap.
  Combines static pages, movies, people, lists, and awards.
  """
  def stream_urls(opts \\ []) do
    [
      static_urls(opts),
      movie_urls(opts),
      person_urls(opts),
      list_urls(opts),
      award_urls(opts)
    ]
    |> Enum.reduce(Stream.concat([]), fn stream, acc ->
      Stream.concat(acc, stream)
    end)
  end

  @doc """
  Returns count of URLs that would be included in sitemap.
  Useful for monitoring and statistics.
  """
  def url_count do
    movies = Repo.one(from m in Movie, where: not is_nil(m.slug), select: count(m.id))
    people = Repo.one(from p in Person, where: not is_nil(p.slug), select: count(p.id))
    lists = length(ListSlugs.all_slugs())

    awards =
      Repo.one(from f in FestivalOrganization, where: not is_nil(f.slug), select: count(f.id))

    # 7 static pages + dynamic content
    static = 7

    %{
      static: static,
      movies: movies,
      people: people,
      lists: lists,
      awards: awards,
      total: static + movies + people + lists + awards
    }
  end

  # Returns a stream of static pages
  defp static_urls(opts) do
    base_url = get_base_url(opts)

    [
      %Sitemapper.URL{
        loc: base_url,
        changefreq: :weekly,
        priority: 1.0,
        lastmod: Date.utc_today()
      },
      %Sitemapper.URL{
        loc: "#{base_url}/movies",
        changefreq: :daily,
        priority: 0.95,
        lastmod: Date.utc_today()
      },
      %Sitemapper.URL{
        loc: "#{base_url}/movies/discover",
        changefreq: :daily,
        priority: 0.9,
        lastmod: Date.utc_today()
      },
      %Sitemapper.URL{
        loc: "#{base_url}/people",
        changefreq: :daily,
        priority: 0.9,
        lastmod: Date.utc_today()
      },
      %Sitemapper.URL{
        loc: "#{base_url}/lists",
        changefreq: :weekly,
        priority: 0.85,
        lastmod: Date.utc_today()
      },
      %Sitemapper.URL{
        loc: "#{base_url}/awards",
        changefreq: :weekly,
        priority: 0.85,
        lastmod: Date.utc_today()
      },
      %Sitemapper.URL{
        loc: "#{base_url}/six-degrees",
        changefreq: :monthly,
        priority: 0.7,
        lastmod: Date.utc_today()
      }
    ]
    |> Stream.map(& &1)
  end

  # Returns a stream of all movies with slugs
  defp movie_urls(opts) do
    base_url = get_base_url(opts)

    from(m in Movie,
      select: %{
        slug: m.slug,
        updated_at: m.updated_at,
        release_date: m.release_date
      },
      where: not is_nil(m.slug) and m.slug != ""
    )
    |> Repo.stream()
    |> Stream.map(fn movie ->
      lastmod = to_date(movie.updated_at) || Date.utc_today()
      priority = calculate_movie_priority(movie.release_date)
      changefreq = calculate_movie_changefreq(movie.release_date)

      %Sitemapper.URL{
        loc: "#{base_url}/movies/#{movie.slug}",
        changefreq: changefreq,
        priority: priority,
        lastmod: lastmod
      }
    end)
  end

  # Returns a stream of all people with slugs
  defp person_urls(opts) do
    base_url = get_base_url(opts)

    from(p in Person,
      select: %{
        slug: p.slug,
        updated_at: p.updated_at,
        popularity: p.popularity
      },
      where: not is_nil(p.slug) and p.slug != ""
    )
    |> Repo.stream()
    |> Stream.map(fn person ->
      lastmod = to_date(person.updated_at) || Date.utc_today()
      priority = calculate_person_priority(person.popularity)

      %Sitemapper.URL{
        loc: "#{base_url}/people/#{person.slug}",
        changefreq: :weekly,
        priority: priority,
        lastmod: lastmod
      }
    end)
  end

  # Returns a stream of all curated lists (static definitions)
  defp list_urls(opts) do
    base_url = get_base_url(opts)

    # Lists are statically defined, not in the database
    ListSlugs.all_slugs()
    |> Stream.map(fn slug ->
      %Sitemapper.URL{
        loc: "#{base_url}/lists/#{slug}",
        changefreq: :weekly,
        priority: 0.8,
        lastmod: Date.utc_today()
      }
    end)
  end

  # Returns a stream of all awards/festival organizations
  defp award_urls(opts) do
    base_url = get_base_url(opts)

    from(f in FestivalOrganization,
      select: %{
        slug: f.slug,
        updated_at: f.updated_at
      },
      where: not is_nil(f.slug) and f.slug != ""
    )
    |> Repo.stream()
    |> Stream.map(fn festival ->
      lastmod = to_date(festival.updated_at) || Date.utc_today()

      %Sitemapper.URL{
        loc: "#{base_url}/awards/#{festival.slug}",
        changefreq: :weekly,
        priority: 0.8,
        lastmod: lastmod
      }
    end)
  end

  # Calculate priority for movies based on recency
  defp calculate_movie_priority(release_date) do
    if release_date do
      days_since_release = Date.diff(Date.utc_today(), release_date)

      cond do
        # Recent releases get highest priority
        days_since_release <= 90 -> 0.9
        days_since_release <= 365 -> 0.8
        days_since_release <= 365 * 3 -> 0.7
        days_since_release <= 365 * 10 -> 0.6
        true -> 0.5
      end
    else
      0.5
    end
  end

  # Calculate changefreq for movies based on release date
  defp calculate_movie_changefreq(release_date) do
    if release_date do
      days_since_release = Date.diff(Date.utc_today(), release_date)

      cond do
        # New releases - might get more data
        days_since_release <= 30 -> :daily
        days_since_release <= 90 -> :weekly
        # Older movies - rarely change
        true -> :monthly
      end
    else
      :monthly
    end
  end

  # Calculate priority for people based on popularity
  defp calculate_person_priority(nil), do: 0.5

  defp calculate_person_priority(popularity) do
    cond do
      popularity >= 50 -> 0.9
      popularity >= 20 -> 0.8
      popularity >= 10 -> 0.7
      popularity >= 5 -> 0.6
      true -> 0.5
    end
  end

  # Convert various datetime types to Date
  defp to_date(nil), do: nil
  defp to_date(%NaiveDateTime{} = naive_dt), do: NaiveDateTime.to_date(naive_dt)
  defp to_date(%DateTime{} = dt), do: DateTime.to_date(dt)
  defp to_date(%Date{} = date), do: date

  # Get the base URL
  defp get_base_url(opts) do
    Keyword.get(opts, :host, @site_url)
  end

  # Get the sitemap configuration
  defp get_sitemap_config(opts) do
    base_url = get_base_url(opts)

    # Always use local file storage
    # In production, these files will be served by Phoenix/nginx
    priv_dir = :code.priv_dir(:cinegraph)
    sitemap_path = Path.join([priv_dir, "static", "sitemaps"])

    # Ensure directory exists
    File.mkdir_p!(sitemap_path)

    Logger.info("Sitemap config - FileStore, path: #{sitemap_path}")

    [
      store: Sitemapper.FileStore,
      store_config: [path: sitemap_path],
      sitemap_url: "#{base_url}/sitemaps"
    ]
  end
end
