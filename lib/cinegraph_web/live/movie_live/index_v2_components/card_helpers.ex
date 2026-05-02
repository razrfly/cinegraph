defmodule CinegraphWeb.MovieLive.IndexV2Components.CardHelpers do
  @moduledoc """
  Result grid and film-card shaping helpers for the V2 movie index.
  """
  use Phoenix.Component

  alias CinegraphWeb.Helpers.UrlHelpers
  alias CinegraphWeb.NeutralV2Components
  alias Cinegraph.Movies.Scoreability

  @lens_keys ~w(mob critics festival_recognition time_machine auteurs)

  attr :movies, :list, required: true
  attr :active_lens_key, :any, default: nil

  def results(assigns) do
    ~H"""
    <section class="mb-8">
      <div :if={@movies == []} class="py-20 text-center">
        <p class="font-display italic text-[28px] text-mist-700">
          No films match these filters.
        </p>
        <button
          phx-click="clear_filters"
          class="mt-4 inline-flex items-center justify-center gap-1 rounded-full bg-mist-950 px-4 py-2 text-sm/7 font-medium text-mist-100 hover:bg-mist-800"
        >
          Clear filters
        </button>
      </div>

      <div
        :if={@movies != []}
        class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6 gap-[18px]"
      >
        <NeutralV2Components.n_film_card
          :for={movie <- @movies}
          film={to_card_shape(movie, @active_lens_key)}
        />
      </div>
    </section>
    """
  end

  defp to_card_shape(movie, active_lens_key) do
    genres = genres_of(movie)
    {score_str, lens_components} = score_for_card(movie, active_lens_key)
    reason = scoreability_reason(movie, active_lens_key)

    %{
      id: movie.id,
      title: movie.title,
      year: year_of(movie.release_date),
      dir: director_of(movie),
      genre: List.first(genres),
      genres: genres,
      score: score_str,
      score_tooltip: score_tooltip_for(active_lens_key),
      lens_key: active_lens_key,
      lens_components: lens_components,
      reason: reason,
      poster_url: tmdb_poster_url(movie.poster_path, "w500"),
      href: movie_href(movie)
    }
  end

  defp score_tooltip_for(lens_key) when lens_key in @lens_keys, do: lens_tooltip(lens_key)
  defp score_tooltip_for(:preset), do: "Cinegraph composite score (Scored Preset)"

  defp score_tooltip_for(_),
    do: "CineGraph score — shown only when at least two evidence lenses are available"

  defp score_for_card(movie, lens_key) when lens_key in @lens_keys do
    cache = loaded_score_cache(movie)
    primary = lens_value(cache, lens_key)
    primary_percent = lens_percent(primary, scale: :zero_to_ten)
    score_str = if primary_percent, do: "#{primary_percent}%", else: nil

    chips =
      @lens_keys
      |> Enum.map(fn k ->
        val = lens_value(cache, k)
        percent = lens_percent(val, scale: :zero_to_ten)
        if percent && percent >= 5, do: {k, percent, lens_tooltip(k)}, else: nil
      end)
      |> Enum.reject(&is_nil/1)

    {score_str, chips}
  end

  defp score_for_card(movie, :preset) do
    case Map.get(movie, :overall_score) do
      v when is_number(v) -> {Float.round(v * 1.0, 1) |> :erlang.float_to_binary(decimals: 1), []}
      _ -> default_score(movie)
    end
  end

  defp score_for_card(movie, _), do: default_score(movie)

  defp default_score(movie) do
    case Scoreability.display_score(movie) || Map.get(movie, :overall_score) do
      v when is_number(v) -> {format_score(v), []}
      _ -> {nil, []}
    end
  end

  defp scoreability_reason(movie, lens_key) when lens_key in @lens_keys do
    case loaded_scoreability(movie) do
      nil ->
        nil

      scoreability ->
        "#{Scoreability.confidence_badge(scoreability)} · #{Scoreability.lens_summary(scoreability)}"
    end
  end

  defp scoreability_reason(movie, _lens_key) do
    case loaded_scoreability(movie) do
      nil ->
        nil

      scoreability ->
        case Scoreability.state(scoreability) do
          "scoreable" ->
            "#{Scoreability.confidence_badge(scoreability)} · #{Scoreability.lens_summary(scoreability)}"

          "limited" ->
            "Limited confidence · #{Scoreability.lens_summary(scoreability)}"

          _ ->
            "Not enough evidence yet"
        end
    end
  end

  defp loaded_score_cache(%{score_cache: %Ecto.Association.NotLoaded{}}), do: nil
  defp loaded_score_cache(%{score_cache: nil}), do: nil
  defp loaded_score_cache(%{score_cache: cache}), do: cache
  defp loaded_score_cache(_), do: nil

  defp loaded_scoreability(%{scoreability: %Ecto.Association.NotLoaded{}}), do: nil
  defp loaded_scoreability(%{scoreability: nil}), do: nil
  defp loaded_scoreability(%{scoreability: scoreability}), do: scoreability
  defp loaded_scoreability(_), do: nil

  defp lens_value(nil, _), do: nil
  defp lens_value(cache, "mob"), do: Map.get(cache, :mob_score)
  defp lens_value(cache, "critics"), do: Map.get(cache, :critics_score)
  defp lens_value(cache, "festival_recognition"), do: Map.get(cache, :festival_recognition_score)
  defp lens_value(cache, "time_machine"), do: Map.get(cache, :time_machine_score)
  defp lens_value(cache, "auteurs"), do: Map.get(cache, :auteurs_score)
  defp lens_value(_, _), do: nil

  defp lens_tooltip("mob"), do: "Audience — IMDb + TMDb + Rotten Tomatoes"
  defp lens_tooltip("critics"), do: "Critics — Metacritic + Rotten Tomatoes"
  defp lens_tooltip("festival_recognition"), do: "Awards — festival wins and major-award presence"
  defp lens_tooltip("time_machine"), do: "All-time canon — Criterion, 1001 Movies, Sight & Sound"
  defp lens_tooltip("auteurs"), do: "Director picks — director and cast quality"
  defp lens_tooltip(_), do: nil

  defp lens_percent(value, opts)
  defp lens_percent(nil, _opts), do: nil

  defp lens_percent(value, opts) when is_number(value) do
    scale = Keyword.get(opts, :scale, :zero_to_ten)
    multiplier = if scale == :zero_to_one, do: 100, else: 10

    value
    |> Kernel.*(multiplier)
    |> round()
    |> max(0)
    |> min(100)
  end

  defp lens_percent(_, _opts), do: nil

  defp format_score(value),
    do: Float.round(value * 1.0, 1) |> :erlang.float_to_binary(decimals: 1)

  defp year_of(%Date{year: y}), do: y
  defp year_of(_), do: nil

  defp tmdb_poster_url(nil, _), do: nil
  defp tmdb_poster_url("", _), do: nil
  defp tmdb_poster_url("/" <> _ = path, size), do: "https://image.tmdb.org/t/p/#{size}#{path}"
  defp tmdb_poster_url(path, size), do: "https://image.tmdb.org/t/p/#{size}/#{path}"

  defp movie_href(%{slug: slug, id: id}), do: UrlHelpers.movie_href(slug, id)
  defp movie_href(%{id: id}), do: UrlHelpers.movie_href(nil, id)

  defp director_of(movie) do
    case movie |> Map.get(:director) |> present_string() do
      nil -> director_from_movie_credits(movie)
      director -> director
    end
  end

  defp genres_of(movie) do
    movie
    |> loaded_assoc(:genres)
    |> Enum.map(&genre_name/1)
    |> Enum.reject(&is_nil/1)
  end

  defp loaded_assoc(movie, assoc) do
    case Map.get(movie, assoc) do
      %Ecto.Association.NotLoaded{} -> []
      nil -> []
      values when is_list(values) -> values
      value -> [value]
    end
  end

  defp director_from_movie_credits(movie) do
    movie
    |> loaded_assoc(:movie_credits)
    |> Enum.find_value(fn
      %{job: "Director", person: %{name: name}} -> present_string(name)
      _ -> nil
    end)
  end

  defp present_string(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp present_string(_), do: nil

  defp genre_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp genre_name(name) when is_binary(name) and name != "", do: name
  defp genre_name(_), do: nil
end
