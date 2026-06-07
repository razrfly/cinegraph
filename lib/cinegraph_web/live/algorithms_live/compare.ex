defmodule CinegraphWeb.AlgorithmsLive.Compare do
  @moduledoc """
  `/algorithms/compare` (#1038 Phase 3) — side-by-side columns of how different list algorithms
  answer for the same seed film. The URL is the whole state (`?seed=<movie-slug>&rails=<slug,slug>`)
  so any comparison is shareable.

  Column semantics are honest about what each algorithm *can* do:

    * **rail** lists (`metadata["rail"]`): seed-conditioned — `VideoClerk.recommend/2` picks with
      the clerk's reasons. Without a seed the column asks for one rather than faking relevance.
    * **predictive** lists (a model is served): top predicted next additions, explicitly labeled
      *not seed-conditioned* — the model predicts the list's next edition, not your taste.
      Per-film % only when the model's probabilities are certified (same gate as everywhere).
    * **unserved** lists: the honest "not metadata-predictable" note. No column is invented.
  """
  use CinegraphWeb, :live_view

  alias Cinegraph.Movies.{Movie, MovieLists}
  alias Cinegraph.Predictions.DisplayCache
  alias Cinegraph.Repo
  alias Cinegraph.Scoring.Bus
  alias Cinegraph.Search
  alias Cinegraph.VideoClerk
  alias CinegraphWeb.AlgorithmsLive.Presentation

  import Ecto.Query

  @default_rails ~w(1001-movies cult-movies-400)
  @max_rails 4
  @column_limit 8

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Compare algorithms")
     |> assign(:active_nav, "Algorithms")
     |> assign(:seed_query, "")
     |> assign(:seed_results, [])
     |> assign(:available, MovieLists.all_displayable())
     |> assign(:signature, nil)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    rail_slugs = parse_rails(params["rails"], socket.assigns.available)
    seed_slug = presence(params["seed"])
    signature = {seed_slug, rail_slugs}

    # A patch that doesn't change seed/rails (e.g. clearing search) must not restart the async loads.
    if socket.assigns.signature == signature do
      {:noreply, socket}
    else
      seed = seed_slug && seed_movie(seed_slug)

      {:noreply,
       socket
       |> assign(:signature, signature)
       |> assign(:rail_slugs, rail_slugs)
       |> assign(:seed, seed)
       |> assign_columns(rail_slugs, seed)}
    end
  end

  defp parse_rails(nil, available), do: known_slugs(@default_rails, available)

  defp parse_rails(rails, available) when is_binary(rails) do
    case rails |> String.split(",", trim: true) |> Enum.uniq() |> known_slugs(available) do
      [] -> known_slugs(@default_rails, available)
      slugs -> Enum.take(slugs, @max_rails)
    end
  end

  defp known_slugs(slugs, available) do
    known = MapSet.new(available, & &1.slug)
    Enum.filter(slugs, &MapSet.member?(known, &1))
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(s) when is_binary(s), do: s

  # ── columns ─────────────────────────────────────────────────────────────────────────
  defp assign_columns(socket, rail_slugs, seed) do
    by_slug = Map.new(socket.assigns.available, &{&1.slug, &1})

    columns =
      Enum.map(rail_slugs, fn slug ->
        list = Map.fetch!(by_slug, slug)
        type = column_type(list)
        %{slug: slug, name: list.name, source_key: list.source_key, type: type}
      end)

    plans = Enum.map(columns, &{&1, load_plan(&1, seed)})

    socket =
      assign(socket, :columns, Enum.map(plans, fn {col, plan} -> column_shell(col, plan) end))

    Enum.reduce(plans, socket, fn
      {_col, nil}, sock -> sock
      {col, fun}, sock -> start_async(sock, {:column, col.slug}, fun)
    end)
  end

  defp column_type(list) do
    cond do
      is_map(list.metadata) and list.metadata["rail"] == true -> :rail
      Bus.active_model(list.source_key) != nil -> :predictive
      true -> :unserved
    end
  end

  # A column with nothing to load (unserved, or a seed-less rail) is ready immediately.
  defp column_shell(col, plan) do
    Map.merge(col, %{
      status: if(plan, do: :loading, else: :ready),
      films: [],
      show_prob?: false
    })
  end

  # What (if anything) to load async for a column. Rail columns are seed-conditioned: without a
  # seed they honestly ask for one instead of faking a ranking.
  defp load_plan(%{type: :rail}, nil), do: nil

  defp load_plan(%{type: :rail}, seed) do
    seed_id = seed.id
    fn -> {:rail, clerk_films(seed_id)} end
  end

  defp load_plan(%{type: :predictive, source_key: sk}, _seed) do
    fn -> {:predictive, DisplayCache.next_additions(sk, limit: @column_limit)} end
  end

  defp load_plan(%{type: :unserved}, _seed), do: nil

  @impl true
  def handle_async({:column, slug}, {:ok, result}, socket) do
    {:noreply, update_column(socket, slug, column_result(result))}
  end

  def handle_async({:column, slug}, {:exit, _reason}, socket) do
    {:noreply, update_column(socket, slug, %{status: :error})}
  end

  defp column_result({:rail, films}), do: %{status: :ready, films: films}

  defp column_result({:predictive, {:ok, result}}),
    do: %{status: :ready, films: prediction_films(result), show_prob?: result.show_prob?}

  defp column_result({:predictive, {:error, :no_active_model}}),
    do: %{status: :ready, films: [], type: :unserved}

  defp update_column(socket, slug, changes) do
    columns =
      Enum.map(socket.assigns.columns, fn
        %{slug: ^slug} = col -> Map.merge(col, changes)
        col -> col
      end)

    assign(socket, :columns, columns)
  end

  # ── events (every change is a URL patch — the URL is the state) ──────────────────────
  @impl true
  def handle_event("seed_search", %{"q" => q}, socket) do
    q = String.trim(to_string(q || ""))

    results =
      if String.length(q) >= 2,
        do: q |> Search.global(limit: 8) |> Map.get(:films, []),
        else: []

    {:noreply, socket |> assign(:seed_query, q) |> assign(:seed_results, results)}
  end

  def handle_event("seed_select", %{"slug" => slug}, socket) do
    {:noreply,
     socket
     |> assign(:seed_query, "")
     |> assign(:seed_results, [])
     |> push_patch(to: compare_path(slug, socket.assigns.rail_slugs))}
  end

  def handle_event("seed_clear", _params, socket) do
    {:noreply, push_patch(socket, to: compare_path(nil, socket.assigns.rail_slugs))}
  end

  def handle_event("rail_toggle", %{"slug" => slug}, socket) do
    rails = socket.assigns.rail_slugs

    rails =
      cond do
        slug in rails -> List.delete(rails, slug)
        length(rails) >= @max_rails -> rails
        true -> rails ++ [slug]
      end

    seed_slug = socket.assigns.seed && socket.assigns.seed.slug
    {:noreply, push_patch(socket, to: compare_path(seed_slug, rails))}
  end

  defp compare_path(seed_slug, rails) do
    query =
      [seed: seed_slug, rails: if(rails != [], do: Enum.join(rails, ","))]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    ~p"/algorithms/compare?#{query}"
  end

  # ── lookups / shaping ─────────────────────────────────────────────────────────────────
  defp seed_movie(slug) do
    Repo.one(
      from m in Movie,
        where: m.slug == ^slug,
        select: %Movie{id: m.id, title: m.title, release_date: m.release_date, slug: m.slug},
        limit: 1
    )
  end

  defp clerk_films(seed_id) do
    result = VideoClerk.recommend([seed_id], limit: @column_limit)

    [result.primary | result.alternates]
    |> Enum.reject(&is_nil/1)
    # Drop the clerk's internal evidence score — rails carry no number, only reasons.
    |> Enum.map(&Map.delete(&1, :score))
  end

  defp prediction_films(result) do
    result.rows
    |> Enum.with_index(1)
    |> Enum.map(fn {r, i} ->
      %{
        id: r.id,
        title: r.title,
        year: r.year,
        rank: i,
        poster_url: poster_url(r.poster_path),
        href: ~p"/movies/#{r.slug || r.id}",
        score: if(result.show_prob?, do: Presentation.prob_str(r.prob))
      }
    end)
  end

  defp poster_url(nil), do: nil
  defp poster_url("/" <> _ = path), do: "https://image.tmdb.org/t/p/w342#{path}"
  defp poster_url(path), do: "https://image.tmdb.org/t/p/w342/#{path}"

  # ── presentation (template) ───────────────────────────────────────────────────────────
  @doc false
  def type_label(:rail), do: "Recommendation rail"
  def type_label(:predictive), do: "Predictive model"
  def type_label(:unserved), do: "Not metadata-predictable"

  @doc false
  def type_tone(:rail), do: "ink"
  def type_tone(:predictive), do: "green"
  def type_tone(:unserved), do: "default"
end
