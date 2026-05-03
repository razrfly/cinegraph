defmodule CinegraphWeb.VideoClerkLive do
  @moduledoc """
  Public mock page for the Video Clerk recommendation concept.
  """
  use CinegraphWeb, :live_view

  import Ecto.Query

  alias Cinegraph.Repo
  alias Cinegraph.Search
  alias Cinegraph.VideoClerk
  alias Cinegraph.Movies
  alias Cinegraph.Movies.Movie

  attr :title, :string, required: true
  attr :eyebrow, :string, required: true
  attr :movies, :list, required: true
  attr :empty, :string, required: true

  def shelf(assigns) do
    ~H"""
    <section>
      <div class="mb-4 flex items-end justify-between gap-4">
        <div>
          <CinegraphWeb.NeutralV2Components.n_eyebrow>
            {@eyebrow}
          </CinegraphWeb.NeutralV2Components.n_eyebrow>
          <h2 class="mt-2 font-display italic text-[34px] leading-tight text-mist-950">
            {@title}
          </h2>
        </div>
      </div>

      <div
        :if={@movies != []}
        class="grid grid-cols-2 gap-4 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6 xl:grid-cols-12"
      >
        <CinegraphWeb.NeutralV2Components.n_film_card
          :for={movie <- @movies}
          film={movie}
          rank={movie.rank}
          show_score={false}
          compact={true}
        />
      </div>

      <div
        :if={@movies == []}
        class="rounded-lg border border-mist-950/10 bg-mist-50 px-4 py-8 text-center text-[13px] text-mist-600"
      >
        {@empty}
      </div>
    </section>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    cult_movies = load_shelf("cult_movies_400")
    canon_movies = load_shelf("1001_movies")

    {:ok,
     socket
     |> assign(:page_title, "The Video Clerk")
     |> assign(:active_nav, "Video Clerk")
     |> assign(:selected_movies, [])
     |> assign(:search_query, "")
     |> assign(:search_results, [])
     |> assign(:recommendation, empty_recommendation())
     |> assign(:routes, routes())
     |> assign(:cult_movies, cult_movies)
     |> assign(:canon_movies, canon_movies)
     |> assign(:demo_films, demo_films())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    selected_movies = selected_movies_from_params(params)

    {:noreply,
     socket
     |> assign(:selected_movies, selected_movies)
     |> assign_recommendation()}
  end

  @impl true
  def handle_event("search_movies", %{"q" => query}, socket) do
    query = String.trim(to_string(query || ""))

    results =
      if String.length(query) >= 2 do
        query
        |> Search.global(limit: 8)
        |> Map.get(:films, [])
        |> Enum.reject(&selected_slug?(socket.assigns.selected_movies, &1.slug))
      else
        []
      end

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:search_results, results)}
  end

  def handle_event("select_movie", %{"slug" => slug}, socket) do
    slugs =
      socket.assigns.selected_movies
      |> Enum.map(&to_string(&1.slug))
      |> add_selected_slug(slug)
      |> Enum.take(3)

    {:noreply,
     socket
     |> assign(:search_query, "")
     |> assign(:search_results, [])
     |> push_patch(to: video_clerk_path(slugs))}
  end

  def handle_event("remove_movie", %{"slug" => slug}, socket) do
    selected = Enum.reject(socket.assigns.selected_movies, &(to_string(&1.slug) == slug))
    {:noreply, push_patch(socket, to: video_clerk_path(selected))}
  end

  def handle_event("reset_clerk", _params, socket) do
    {:noreply,
     socket
     |> assign(:search_query, "")
     |> assign(:search_results, [])
     |> push_patch(to: ~p"/video-clerk")}
  end

  def handle_event("load_demo", _params, socket) do
    slugs =
      demo_films()
      |> Enum.map(& &1.slug)
      |> Enum.take(3)

    {:noreply, push_patch(socket, to: video_clerk_path(slugs))}
  end

  defp load_shelf(source_key) do
    source_key
    |> Movies.list_canonical_shelf_movies(12)
    |> Enum.with_index(1)
    |> Enum.map(fn {movie, rank} -> movie_card(movie, source_key, rank) end)
  end

  defp movie_card(%Movie{} = movie, source_key, rank) do
    metadata = Movie.canonical_metadata(movie, source_key) || %{}

    %{
      title: movie.title,
      year: Movie.release_year(movie),
      poster_url: Movie.poster_url(movie, "w342"),
      href: movie_href(movie),
      rank: normalize_rank(metadata["list_position"], rank),
      reason: metadata["source_name"] || source_key,
      dir: list_label(source_key),
      score: nil
    }
  end

  defp movie_href(%Movie{slug: slug}) when not is_nil(slug), do: ~p"/movies/#{slug}"

  defp movie_href(%Movie{imdb_id: imdb_id}) when is_binary(imdb_id),
    do: ~p"/movies/imdb/#{imdb_id}"

  defp movie_href(_movie), do: "#"

  defp list_label("cult_movies_400"), do: "Cult source"
  defp list_label("1001_movies"), do: "Cultural canon"
  defp list_label(source_key), do: source_key

  defp normalize_rank(position, _fallback) when is_integer(position), do: position

  defp normalize_rank(position, fallback) when is_binary(position) do
    case Integer.parse(position) do
      {rank, ""} -> rank
      _ -> fallback
    end
  end

  defp normalize_rank(_position, fallback), do: fallback

  defp selected_movies_from_params(%{"movies" => movies}) when is_binary(movies) do
    movies
    |> String.split(",", trim: true)
    |> Enum.take(3)
    |> movies_by_slugs()
  end

  defp selected_movies_from_params(%{"seed" => seed}) when is_binary(seed) do
    seed
    |> List.wrap()
    |> movies_by_slugs()
  end

  defp selected_movies_from_params(_params), do: []

  defp movies_by_slugs([]), do: []

  defp movies_by_slugs(slugs) do
    Movie
    |> where([m], m.slug in ^slugs)
    |> where([m], m.import_status == "full")
    |> Repo.replica().all()
    |> Enum.sort_by(fn movie -> Enum.find_index(slugs, &(&1 == to_string(movie.slug))) || 999 end)
  end

  defp add_selected_slug(selected, slug) do
    slug = to_string(slug)

    cond do
      selected_slug?(selected, slug) ->
        selected

      length(selected) >= 3 ->
        selected

      true ->
        selected ++ [slug]
    end
  end

  defp selected_slug?(selected, slug) do
    Enum.any?(selected, fn
      %Movie{slug: selected_slug} -> to_string(selected_slug) == to_string(slug)
      selected_slug -> to_string(selected_slug) == to_string(slug)
    end)
  end

  defp pick_slots(selected) do
    count = max(3 - length(selected), 0)
    if count == 0, do: [], else: Enum.to_list(1..count)
  end

  defp assign_recommendation(socket) do
    result =
      socket.assigns.selected_movies
      |> Enum.map(& &1.id)
      |> VideoClerk.recommend(limit: 4)

    assign(socket, :recommendation, result)
  end

  defp empty_recommendation do
    %{primary: nil, alternates: [], seed_movies: [], route_labels: [], evidence_summary: []}
  end

  defp video_clerk_path([]), do: ~p"/video-clerk"

  defp video_clerk_path(selected) do
    slugs =
      selected
      |> Enum.map(fn
        %Movie{slug: slug} -> slug
        slug -> slug
      end)
      |> Enum.join(",")

    ~p"/video-clerk?#{%{movies: slugs}}"
  end

  defp demo_films do
    [
      %{title: "Donnie Darko", year: "2001", slug: "donnie-darko-2001"},
      %{title: "Napoleon Dynamite", year: "2004", slug: "napoleon-dynamite-2004"},
      %{title: "Ghost World", year: "2001", slug: "ghost-world-2001"}
    ]
  end

  defp routes do
    [
      %{
        title: "Cult Classic",
        body:
          "Start with movies that built a second life through obsession, quotation, midnight screenings, and misfit affection."
      },
      %{
        title: "1001 / Cultural Relevance",
        body:
          "Use the canon as a pressure test: not because canon is law, but because cultural memory leaves evidence."
      },
      %{
        title: "Human Graph",
        body:
          "Follow directors, writers, actors, crews, countries, movements, and production histories instead of anonymous co-watch behavior."
      },
      %{
        title: "Disagreement",
        body:
          "Look for taste tension: movies critics defend, audiences rescue, or history corrects later."
      },
      %{
        title: "Tonight",
        body:
          "Respect the mood. Sometimes the right answer is stranger, shorter, funnier, sadder, or just easier to start."
      }
    ]
  end
end
