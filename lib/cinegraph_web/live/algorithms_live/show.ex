defmodule CinegraphWeb.AlgorithmsLive.Show do
  @moduledoc """
  Public `/algorithms/:slug` show page (#1038 2a/2b/2c) — mode-aware:

    * **:predictive** (a model is served): the honest accuracy block, a **live probe**, poster-grid
      **Predictions / Members** tabs (`n_film_card`), the **profile switcher + embedded tuner**
      (Dial 2 — the resurrected `/movies/discover`), **worst misses**, and the model internals
      collapsed below. Predictions load async; switching off "Trained model" swaps the ranking to a
      lens-cache re-rank with an explicit *unvalidated* notice — **no accuracy claim ever attaches
      to a custom profile**.
    * **:rail** (`list.metadata["rail"]`): recommendation-rail mode — the "how this rail thinks"
      thesis, an optional seed picker (`VideoClerk.recommend/2`), the picks grid with
      disparity/unpredictability reasons, and the same tuner re-ranking the shelf. No %, ever.
    * **:unserved**: the honest "not metadata-predictable" panel + a Members grid.
  """
  use CinegraphWeb, :live_view

  alias Cinegraph.Movies.{DiscoveryCommon, DiscoveryScoringSimple, Movie, MovieLists}
  alias Cinegraph.Movies.MovieScoreCache
  alias Cinegraph.Predictions.{Candidates, DisplayCache, Explanation, ListFrontier}
  alias Cinegraph.Repo
  alias Cinegraph.Scoring.{Bus, Lenses}
  alias Cinegraph.Search
  alias Cinegraph.VideoClerk
  alias CinegraphWeb.AlgorithmsLive.Presentation

  import Ecto.Query

  # Cap the on-page weight list; the rest are summarized.
  @max_weights 18
  @grid_limit 24
  @tabs ~w(all predictions members)
  @views ~w(list grid)
  @members_limit 48
  @max_seeds 3

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_nav, "Algorithms")
     |> assign(:list_query, "")
     |> assign(:list_results, [])
     |> assign(:probe, nil)
     |> assign(:profile, "trained")
     |> assign(:weights, Lenses.default_atom_weights())
     |> assign(:min_score, 0.0)
     |> assign(:tuned, nil)
     |> assign(:presets, preset_names())
     |> assign(:rail_query, "")
     |> assign(:rail_results, [])
     |> assign(:rail_seeds, [])
     |> assign(:picks, [])}
  end

  @impl true
  def handle_params(%{"slug" => slug} = params, _url, socket) do
    case MovieLists.get_by_slug(slug) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Algorithm list not found")
         |> push_navigate(to: ~p"/algorithms")}

      list ->
        tab = if params["tab"] in @tabs, do: params["tab"], else: "all"

        # NOTE: `:view` is taken (the Explanation payload, `v = @view` in the template) — the
        # list/grid toggle lives in `:display` (the URL param stays `?view=` for readability).
        socket =
          socket
          |> assign(:tab, tab)
          |> assign(
            :display,
            if(params["view"] in @views, do: params["view"], else: default_view(tab))
          )

        # Only (re)load page data when the list actually changed — a tab patch must not restart the
        # async predictions or reset the tuner.
        if socket.assigns[:list] && socket.assigns.list.id == list.id do
          {:noreply, socket}
        else
          view = view_for(list)
          mode = mode_for(list, view)

          {:noreply,
           socket
           |> assign(:page_title, list.name)
           |> assign(:list, list)
           |> assign(:archetype, Presentation.archetype(list.source_key))
           |> assign(:view, view)
           |> assign(:mode, mode)
           |> assign(:profile, if(mode == :rail, do: "cult_classic", else: "trained"))
           |> assign(:weights, initial_weights(mode))
           |> assign(:tuned, nil)
           |> assign_mode_data(list, mode)}
        end
    end
  end

  # The unified ranked view defaults to list rows (the why-line needs the width); the
  # predictions/members tabs keep their poster grids.
  defp default_view("all"), do: "list"
  defp default_view(_tab), do: "grid"

  # Rail metadata takes precedence over a served model — same classification order as the
  # index's build_card/1 and compare's column_type/1 (a rail never surfaces predictive-accuracy UI).
  defp mode_for(list, view) do
    cond do
      is_map(list.metadata) and list.metadata["rail"] == true -> :rail
      view.served? -> :predictive
      true -> :unserved
    end
  end

  defp initial_weights(:rail), do: DiscoveryCommon.get_presets()[:cult_classic]
  defp initial_weights(_), do: Lenses.default_atom_weights()

  # Members are a cheap bounded query (sync); predictions scan the frontier-gated catalog and score
  # it through the Bus — async so the page paints first.
  defp assign_mode_data(socket, list, :predictive) do
    sk = list.source_key
    integrity = integrity_for(sk)

    socket
    |> assign(:members, member_films(sk))
    |> assign(:member_count, Candidates.member_count(sk))
    |> assign(:misses, integrity.misses)
    |> assign(:by_decade, integrity.by_decade)
    |> assign(:predictions, :loading)
    |> assign(:ranked_members, :loading)
    |> assign(:members_shown, @members_limit)
    |> assign(:members_more_pending, false)
    |> start_async(:predictions, fn -> DisplayCache.next_additions(sk, limit: @grid_limit) end)
    |> start_async(:ranked_members, fn ->
      DisplayCache.ranked_members(sk, limit: @members_limit)
    end)
  end

  defp assign_mode_data(socket, list, :rail) do
    sk = list.source_key

    socket
    |> assign(:members, member_films(sk))
    |> assign(:member_count, Candidates.member_count(sk))
    |> assign(:misses, nil)
    |> assign(:predictions, :none)
    |> assign(:picks, shelf_picks(sk, socket.assigns.weights, socket.assigns.min_score))
  end

  defp assign_mode_data(socket, list, :unserved) do
    sk = list.source_key

    socket
    |> assign(:members, member_films(sk))
    |> assign(:member_count, Candidates.member_count(sk))
    |> assign(:misses, nil)
    |> assign(:predictions, :none)
  end

  # ── async results ─────────────────────────────────────────────────────────────────
  @impl true
  def handle_async(:predictions, {:ok, {:ok, result}}, socket) do
    {:noreply,
     assign(socket, :predictions, %{
       films: prediction_films(result),
       rows: list_rows(result),
       show_prob?: result.show_prob?,
       cutoff: result.cutoff,
       scanned: result.scanned
     })}
  end

  def handle_async(:predictions, {:ok, {:error, :no_active_model}}, socket),
    do: {:noreply, assign(socket, :predictions, :none)}

  def handle_async(:predictions, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :predictions, :error)}

  def handle_async(:ranked_members, {:ok, {:ok, result}}, socket) do
    {:noreply,
     socket
     |> assign(:ranked_members, %{rows: list_rows(result), total: result.member_count})
     |> assign(:members_more_pending, false)}
  end

  def handle_async(:ranked_members, {:ok, {:error, :no_active_model}}, socket),
    do: {:noreply, assign(socket, :ranked_members, :none)}

  def handle_async(:ranked_members, {:exit, _reason}, socket),
    do:
      {:noreply,
       socket |> assign(:ranked_members, :error) |> assign(:members_more_pending, false)}

  def handle_async(:probe, {:ok, probe}, socket), do: {:noreply, assign(socket, :probe, probe)}
  def handle_async(:probe, {:exit, _reason}, socket), do: {:noreply, assign(socket, :probe, nil)}

  def handle_async(:picks, {:ok, picks}, socket), do: {:noreply, assign(socket, :picks, picks)}
  def handle_async(:picks, {:exit, _reason}, socket), do: {:noreply, socket}

  # ── unified list search + probe (#1077: one search box, two behaviors) ─────────────
  # Typing filters the loaded rows (assigns-side); when nothing visible matches, the catalog
  # results below offer "score it for this list" → the probe.
  @impl true
  def handle_event("list_search", %{"q" => q}, socket) do
    q = String.trim(to_string(q || ""))

    results =
      q
      |> film_search()
      |> Enum.reject(&MapSet.member?(visible_ids(socket.assigns), &1.id))

    {:noreply, socket |> assign(:list_query, q) |> assign(:list_results, results)}
  end

  def handle_event("probe_select", %{"slug" => slug}, socket) do
    sk = socket.assigns.list.source_key

    case probe_movie(slug) do
      nil ->
        {:noreply, socket}

      movie ->
        {:noreply,
         socket
         |> assign(:probe, :loading)
         |> assign(:list_results, [])
         |> assign(:list_query, "")
         |> start_async(:probe, fn -> run_probe(sk, movie) end)}
    end
  end

  def handle_event("probe_clear", _params, socket) do
    {:noreply,
     socket |> assign(:probe, nil) |> assign(:list_results, []) |> assign(:list_query, "")}
  end

  def handle_event("show_more_members", _params, socket) do
    sk = socket.assigns.list.source_key
    shown = socket.assigns.members_shown + @members_limit

    {:noreply,
     socket
     |> assign(:members_shown, shown)
     |> assign(:members_more_pending, true)
     |> start_async(:ranked_members, fn ->
       DisplayCache.ranked_members(sk, limit: shown)
     end)}
  end

  # ── tuner / profile events (#1038 2c) ──────────────────────────────────────────────
  def handle_event("select_profile", %{"profile" => "trained"}, socket) do
    {:noreply,
     socket
     |> assign(:profile, "trained")
     |> assign(:weights, Lenses.default_atom_weights())
     |> assign(:tuned, nil)}
  end

  def handle_event("select_profile", %{"profile" => "custom"}, socket) do
    {:noreply, socket |> assign(:profile, "custom") |> retune()}
  end

  def handle_event("select_profile", %{"profile" => preset}, socket) do
    case Map.fetch(preset_weights(), preset) do
      {:ok, weights} ->
        {:noreply, socket |> assign(:profile, preset) |> assign(:weights, weights) |> retune()}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("update_weights", params, socket) do
    weights =
      Enum.reduce(Lenses.all(), socket.assigns.weights, fn lens, acc ->
        case Float.parse(to_string(params[to_string(lens)] || "")) do
          {v, _} -> Map.put(acc, lens, min(1.0, max(0.0, v / 100)))
          :error -> acc
        end
      end)

    {:noreply, socket |> assign(:weights, weights) |> assign(:profile, "custom") |> retune()}
  end

  def handle_event("update_min_score", %{"min_score" => value}, socket) do
    # Slider is 0–80 (%); movie_score_caches.overall_score is 0–10 — pass the same scale the
    # SQL filter compares against (sc.overall_score >= min_score).
    min_score =
      case Float.parse(to_string(value)) do
        {v, _} -> min(10.0, max(0.0, v / 10))
        :error -> 0.0
      end

    {:noreply, socket |> assign(:min_score, min_score) |> retune()}
  end

  def handle_event("reset_tuner", _params, socket) do
    case socket.assigns.mode do
      :rail ->
        {:noreply,
         socket
         |> assign(:profile, "cult_classic")
         |> assign(:weights, initial_weights(:rail))
         |> assign(:min_score, 0.0)
         |> retune()}

      _ ->
        {:noreply,
         socket
         |> assign(:profile, "trained")
         |> assign(:weights, Lenses.default_atom_weights())
         |> assign(:min_score, 0.0)
         |> assign(:tuned, nil)}
    end
  end

  # ── rail seed events (#1038 2b) ─────────────────────────────────────────────────────
  def handle_event("rail_search", %{"q" => q}, socket) do
    {:noreply,
     socket
     |> assign(:rail_query, String.trim(to_string(q || "")))
     |> assign(:rail_results, film_search(q))}
  end

  def handle_event("rail_seed", %{"slug" => slug}, socket) do
    seeds = socket.assigns.rail_seeds

    with movie when not is_nil(movie) <- probe_movie(slug),
         false <- Enum.any?(seeds, &(&1.id == movie.id)) do
      seeds =
        Enum.take(seeds ++ [%{id: movie.id, title: movie.title, slug: movie.slug}], @max_seeds)

      {:noreply,
       socket
       |> assign(:rail_seeds, seeds)
       |> assign(:rail_results, [])
       |> assign(:rail_query, "")
       |> load_clerk_picks(seeds)}
    else
      _ -> {:noreply, socket |> assign(:rail_results, []) |> assign(:rail_query, "")}
    end
  end

  def handle_event("rail_seed_remove", %{"slug" => slug}, socket) do
    seeds = Enum.reject(socket.assigns.rail_seeds, &(to_string(&1.slug) == to_string(slug)))
    sk = socket.assigns.list.source_key

    socket = assign(socket, :rail_seeds, seeds)

    if seeds == [] do
      {:noreply,
       assign(socket, :picks, shelf_picks(sk, socket.assigns.weights, socket.assigns.min_score))}
    else
      {:noreply, load_clerk_picks(socket, seeds)}
    end
  end

  defp load_clerk_picks(socket, seeds) do
    ids = Enum.map(seeds, & &1.id)
    start_async(socket, :picks, fn -> clerk_picks(ids) end)
  end

  defp clerk_picks(seed_ids) do
    result = VideoClerk.recommend(seed_ids, limit: 12)
    Enum.reject([result.primary | result.alternates], &is_nil/1)
  end

  # ── re-rank (lens-cache path — the same universe, no accuracy claim) ────────────────
  defp retune(socket) do
    sk = socket.assigns.list.source_key

    case socket.assigns.mode do
      :rail ->
        if socket.assigns.rail_seeds == [] do
          assign(
            socket,
            :picks,
            shelf_picks(sk, socket.assigns.weights, socket.assigns.min_score)
          )
        else
          socket
        end

      :predictive ->
        cutoff = ListFrontier.resolve(sk).cutoff_year

        films =
          sk
          |> Candidates.universe_query(mode: "predictions", cutoff: cutoff)
          # apply_scoring sets its own `select: m` — the universe query's select must go.
          |> exclude(:select)
          |> DiscoveryScoringSimple.apply_scoring(socket.assigns.weights, %{
            min_score: socket.assigns.min_score
          })
          |> limit(@grid_limit)
          |> Repo.all()
          |> Enum.with_index(1)
          |> Enum.map(fn {m, i} -> Map.put(movie_film(m), :rank, i) end)

        assign(socket, :tuned, films)

      _ ->
        socket
    end
  end

  defp shelf_picks(source_key, weights, min_score) do
    source_key
    |> Candidates.universe_query(mode: "members")
    # apply_scoring sets its own `select: m` — the universe query's select must go.
    |> exclude(:select)
    |> DiscoveryScoringSimple.apply_scoring(weights, %{min_score: min_score})
    |> limit(@grid_limit)
    |> Repo.all()
    |> attach_disparity()
    |> Enum.with_index(1)
    |> Enum.map(fn {{m, reason}, i} ->
      m |> movie_film() |> Map.merge(%{rank: i, reason: reason})
    end)
  end

  # Surface the engine's disparity/unpredictability as the visible "why it rhymes" (#857/#1038 2b).
  defp attach_disparity(movies) do
    ids = Enum.map(movies, & &1.id)

    caches =
      Repo.all(
        from sc in MovieScoreCache,
          where: sc.movie_id in ^ids,
          select: {sc.movie_id, sc.disparity_category, sc.unpredictability_score}
      )
      |> Map.new(fn {id, cat, unp} -> {id, {cat, unp}} end)

    Enum.map(movies, fn m -> {m, disparity_reason(Map.get(caches, m.id))} end)
  end

  defp disparity_reason(nil), do: nil

  defp disparity_reason({cat, unp}) do
    cat_text =
      case cat do
        "critics_darling" -> "⚔ critics' darling — the crowd disagrees"
        "peoples_champion" -> "⚔ people's champion — the critics disagree"
        "polarizer" -> "⚔ polarizer — strong critic/crowd split"
        _ -> nil
      end

    unp_text = if is_number(unp) and unp >= 2.0, do: "🌀 unpredictable lens profile"

    case Enum.reject([cat_text, unp_text], &is_nil/1) do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  # ── shared lookups / shaping ─────────────────────────────────────────────────────────
  defp film_search(q) do
    q = String.trim(to_string(q || ""))

    if String.length(q) >= 2,
      do: q |> Search.global(limit: 8) |> Map.get(:films, []),
      else: []
  end

  defp run_probe(source_key, movie) do
    case Candidates.probe(source_key, movie) do
      {:error, :no_active_model} ->
        nil

      {:ok, p} ->
        %{
          title: movie.title,
          year: movie.release_date && movie.release_date.year,
          prob_str: if(p.show_prob?, do: Presentation.prob_str(p.prob)),
          score_str: :erlang.float_to_binary(p.score * 1.0, decimals: 1),
          member?: p.member?,
          eligible?: p.eligible?,
          why: p.why,
          present_features: p.present_features,
          total_features: p.total_features,
          lenses: probe_lenses(movie.id)
        }
    end
  end

  # The movie's 6-lens profile from the score cache — context for the probe result, distinct from
  # (and labeled as not being) the Bus model's score.
  defp probe_lenses(movie_id) do
    case Repo.get_by(MovieScoreCache, movie_id: movie_id) do
      nil ->
        []

      sc ->
        [
          {"mob", sc.mob_score},
          {"critics", sc.critics_score},
          {"festival", sc.festival_recognition_score},
          {"canon", sc.time_machine_score},
          {"auteurs", sc.auteurs_score},
          {"box office", sc.box_office_score}
        ]
        |> Enum.reject(fn {_l, v} -> is_nil(v) end)
        # cache lens scores are 0–10 → percent
        |> Enum.map(fn {l, v} -> {l, round(v * 10)} end)
    end
  end

  # The Bus's data-point feature assembly needs canonical_sources + release_date (same shape as
  # Candidates' own query).
  defp probe_movie(slug) do
    Repo.one(
      from m in Movie,
        where: m.slug == ^to_string(slug),
        select: %Movie{
          id: m.id,
          title: m.title,
          release_date: m.release_date,
          canonical_sources: m.canonical_sources,
          poster_path: m.poster_path,
          slug: m.slug
        },
        limit: 1
    )
  end

  defp view_for(list) do
    case Explanation.for_list(list.source_key) do
      {:error, :no_active_model} ->
        %{served?: false}

      {:ok, e} ->
        weights = e.weights || []
        shown = Enum.take(weights, @max_weights)
        max_abs = weights |> Enum.map(&abs(&1.weight)) |> Enum.max(fn -> 1.0 end)

        %{
          served?: true,
          grade: e.grade,
          tier: Presentation.tier(e.grade),
          tier_tone: Presentation.tier_tone(e.grade),
          headline_pct: e.headline_accuracy,
          recall: e.lift && e.lift.recall,
          lift_ratio: e.lift && e.lift.ratio,
          lift_passes?: e.lift && e.lift.passes?,
          circularity: e.circularity,
          model_label: e.model_label,
          strategy: e.strategy,
          shown_weights: shown,
          shown_count: length(shown),
          total_weights: length(weights),
          max_abs: max_abs,
          objective_count: Enum.count(weights, &(&1.bucket == :objective)),
          canon_count: Enum.count(weights, &(&1.bucket == :canon_overlap)),
          rivals: e.rivals || []
        }
    end
  end

  defp integrity_for(source_key) do
    case Bus.active_model(source_key) do
      nil ->
        %{misses: nil, by_decade: []}

      model ->
        %{
          misses: model.integrity_report["worst_miss"],
          by_decade: model.integrity_report["by_decade"] || []
        }
    end
  end

  defp member_films(source_key) do
    source_key
    |> Candidates.members(limit: @grid_limit)
    |> Enum.map(&movie_film/1)
  end

  defp movie_film(m) do
    %{
      id: m.id,
      title: m.title,
      year: m.release_date && m.release_date.year,
      poster_url: Presentation.poster_url(m.poster_path),
      href: ~p"/movies/#{m.slug || m.id}"
    }
  end

  # Rows for the unified ranked list (#1077) — same shape for predictions and members: one
  # model-score scale, the exact why, the signals-density count. JSON-safe maps for film_row.
  defp list_rows(result) do
    total = map_size(result.model.weights || %{})

    result.rows
    |> Enum.with_index(1)
    |> Enum.map(fn {r, i} ->
      %{
        id: r.id,
        title: r.title,
        year: r.year,
        rank: i,
        score: r.score,
        prob_str: if(result.show_prob?, do: Presentation.prob_str(r.prob)),
        member?: r.member?,
        why: r.why,
        signals_present: r.signals_present,
        total_features: total,
        also_on: r.also_on,
        poster_url: Presentation.poster_url(r.poster_path),
        href: ~p"/movies/#{r.slug || r.id}"
      }
    end)
  end

  # Assigns-side title filter for the unified list (≤ 24+48 loaded rows — no DB round-trip).
  @doc false
  def filter_rows(rows, ""), do: rows
  def filter_rows(rows, nil), do: rows

  def filter_rows(rows, q) do
    down = String.downcase(q)
    Enum.filter(rows, &String.contains?(String.downcase(&1.title), down))
  end

  # Every film id currently renderable in the unified view — catalog search results exclude
  # these (they're already on screen; searching should filter, not duplicate).
  defp visible_ids(assigns) do
    prediction_ids =
      case assigns[:predictions] do
        %{rows: rows} -> Enum.map(rows, & &1.id)
        _ -> []
      end

    member_ids =
      case assigns[:ranked_members] do
        %{rows: rows} -> Enum.map(rows, & &1.id)
        _ -> []
      end

    MapSet.new(prediction_ids ++ member_ids)
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
        poster_url: Presentation.poster_url(r.poster_path),
        href: ~p"/movies/#{r.slug || r.id}",
        score: if(result.show_prob?, do: Presentation.prob_str(r.prob)),
        reason: why_reason(r[:why] || [], r.also_on)
      }
    end)
  end

  # The card's one-line "why" (#1076 P1) — the film's top exact model contributions, with
  # also-on as trailing supporting evidence. The full breakdown lives on the probe (and the
  # unified list view, #1077).
  defp why_reason([], also_on), do: also_on_reason(also_on)

  defp why_reason(why, also_on) do
    parts =
      why |> Enum.take(3) |> Enum.map(&"#{&1.label} #{Presentation.signed(&1.contribution)}")

    tail = if also_on != [], do: ["also on: " <> Enum.join(also_on, ", ")], else: []
    Enum.join(parts ++ tail, " · ")
  end

  defp also_on_reason([]), do: nil
  defp also_on_reason(lists), do: "also on: " <> Enum.join(lists, ", ")

  defp preset_weights do
    Map.new(DiscoveryCommon.get_presets(), fn {name, weights} -> {to_string(name), weights} end)
  end

  defp preset_names, do: DiscoveryCommon.get_presets() |> Map.keys() |> Enum.map(&to_string/1)

  # ── presentation helpers (template) ───────────────────────────────────────────────
  @doc false
  def headline(n) when is_number(n), do: "#{:erlang.float_to_binary(n * 1.0, decimals: 1)}%"
  def headline(other), do: to_string(other)

  @doc false
  def pct(n) when is_number(n), do: "#{:erlang.float_to_binary(n * 1.0, decimals: 0)}%"
  def pct(_), do: "—"

  @doc false
  def weight_pct(n) when is_number(n), do: "#{:erlang.float_to_binary(n * 100.0, decimals: 1)}"
  def weight_pct(_), do: "0.0"

  @doc false
  # Ratio is only meaningful when the popularity baseline is > 0; when it's ~0 (popularity finds
  # essentially none), fall back to the pass/fail margin so we don't misreport a real win as "no lift".
  def lift_text(r, _passes?) when is_number(r) and r > 0.0,
    do: "#{:erlang.float_to_binary(r * 1.0, decimals: 1)}× vs popularity"

  def lift_text(_r, true), do: "beats the popularity baseline"
  def lift_text(_r, _passes?), do: "no lift over popularity"

  @doc false
  def circularity_pct(c) when is_number(c), do: "#{round(c * 100)}%"
  def circularity_pct(_), do: nil

  @doc false
  def bar_width(weight, max_abs) when is_number(weight) and is_number(max_abs) and max_abs > 0.0,
    do: "#{Float.round(abs(weight) / max_abs * 100, 1)}%"

  def bar_width(_, _), do: "0%"

  @doc false
  def rival_recall(r) when is_number(r), do: "#{:erlang.float_to_binary(r * 100.0, decimals: 1)}%"
  def rival_recall(_), do: "—"
end
