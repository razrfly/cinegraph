defmodule CinegraphWeb.RatingComponents do
  @moduledoc """
  Provides branded rating badge components using Simple Icons.

  Rating sources display with official brand icons and colors from
  the Simple Icons library (https://simpleicons.org).
  """
  use Phoenix.Component

  @icon_config %{
    "imdb" => %{
      slug: "imdb",
      color: "F5C518",
      name: "IMDb",
      scale: "0-10",
      description: "Internet Movie Database user rating based on votes from registered users."
    },
    "tmdb" => %{
      slug: "themoviedatabase",
      color: "01D277",
      name: "TMDb",
      scale: "0-10",
      description: "The Movie Database community rating from user votes worldwide."
    },
    "rotten_tomatoes" => %{
      slug: "rottentomatoes",
      color: "FA320A",
      name: "Tomatometer",
      scale: "0-100",
      icon_type: :tomato,
      description:
        "Rotten Tomatoes Tomatometer - percentage of positive reviews from approved critics. This is the critic score, not the audience score (Popcornmeter)."
    },
    "rotten_tomatoes_audience" => %{
      slug: "rottentomatoes",
      color: "FA320A",
      name: "Audience Score",
      scale: "0-100",
      icon_type: :popcorn,
      description:
        "Rotten Tomatoes audience score - percentage of users who rated this 3.5 stars or higher."
    },
    "metacritic" => %{
      slug: "metacritic",
      color: "FFCC34",
      name: "Metacritic",
      scale: "0-100",
      description:
        "Metacritic Metascore - weighted average of critic reviews from top publications."
    },
    "letterboxd" => %{
      slug: "letterboxd",
      color: "00D735",
      name: "Letterboxd",
      scale: "0-5",
      description: "Letterboxd community rating from film enthusiasts and cinephiles."
    }
  }

  # Map source display names to source keys
  @source_name_map %{
    "IMDb" => "imdb",
    "IMDB" => "imdb",
    "imdb" => "imdb",
    "TMDb" => "tmdb",
    "TMDB" => "tmdb",
    "tmdb" => "tmdb",
    "The Movie Database" => "tmdb",
    "Rotten Tomatoes" => "rotten_tomatoes",
    "RottenTomatoes" => "rotten_tomatoes",
    "Tomatometer" => "rotten_tomatoes",
    "Audience Score" => "rotten_tomatoes_audience",
    "Metacritic" => "metacritic",
    "metacritic" => "metacritic",
    "Letterboxd" => "letterboxd",
    "letterboxd" => "letterboxd"
  }

  @doc """
  Normalizes a source name to a key for icon lookup.
  """
  def normalize_source(name) when is_binary(name) do
    Map.get(@source_name_map, name, String.downcase(name))
  end

  def normalize_source(_), do: "unknown"

  @doc """
  Renders a branded rating badge with an official source icon.

  ## Examples

      <.rating_badge source="imdb" value={7.8} />
      <.rating_badge source="rotten_tomatoes" value={92} vote_count={450} />
      <.rating_badge source="tmdb" value={7.7} variant={:compact} />
  """
  attr :source, :string,
    required: true,
    doc: "Rating source key (imdb, tmdb, rotten_tomatoes, etc.)"

  attr :value, :any, required: true, doc: "The rating value (number or string)"
  attr :vote_count, :integer, default: nil, doc: "Optional vote count to display"

  attr :variant, :atom,
    default: :default,
    values: [:default, :compact, :hero],
    doc: "Display variant"

  attr :class, :string, default: "", doc: "Additional CSS classes"

  def rating_badge(assigns) do
    config =
      Map.get(@icon_config, assigns.source, %{
        slug: "film",
        color: "666666",
        name: "Unknown",
        scale: nil
      })

    assigns = assign(assigns, :config, config)

    ~H"""
    <div class={badge_classes(@variant, @class)}>
      <.rating_icon source={@source} config={@config} variant={@variant} />
      <div class={value_container_classes(@variant)}>
        <div class={value_classes(@variant)}>
          {format_value(@value, @config.scale)}
        </div>
        <div class={label_classes(@variant)}>
          {@config.name}
        </div>
        <%= if @vote_count && @variant != :compact do %>
          <div class="text-xs text-white/40 mt-0.5">
            {format_vote_count(@vote_count)} votes
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders a rating icon using Simple Icons CDN.
  """
  attr :source, :string, required: true
  attr :config, :map, required: true
  attr :variant, :atom, default: :default

  def rating_icon(assigns) do
    ~H"""
    <%= case @config[:icon_type] do %>
      <% :popcorn -> %>
        <div class={icon_container_classes(@variant)}>
          <span class={emoji_icon_classes(@variant)}>🍿</span>
        </div>
      <% :tomato -> %>
        <div class={icon_container_classes(@variant)}>
          <span class={emoji_icon_classes(@variant)}>🍅</span>
        </div>
      <% _ -> %>
        <img
          src={"https://cdn.simpleicons.org/#{@config.slug}/#{@config.color}"}
          alt={@config.name}
          class={icon_classes(@variant)}
          loading="lazy"
        />
    <% end %>
    """
  end

  @doc """
  Renders a row of rating badges.

  ## Examples

      <.rating_row ratings={@movie.external_ratings} variant={:hero} />
  """
  attr :ratings, :list, required: true, doc: "List of rating maps with source and value keys"
  attr :variant, :atom, default: :default
  attr :class, :string, default: ""

  def rating_row(assigns) do
    ~H"""
    <div class={["flex flex-wrap gap-3", @class]}>
      <%= for rating <- @ratings do %>
        <.rating_badge
          source={rating.source}
          value={rating.value}
          vote_count={Map.get(rating, :vote_count)}
          variant={@variant}
        />
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a grid of rating cards for the overview section.
  """
  attr :ratings, :list, required: true
  attr :class, :string, default: ""

  def rating_grid(assigns) do
    ~H"""
    <div class={["grid grid-cols-2 md:grid-cols-4 gap-4", @class]}>
      <%= for rating <- @ratings do %>
        <.rating_card
          source={rating.source}
          value={rating.value}
          vote_count={Map.get(rating, :vote_count)}
          scale={Map.get(rating, :scale)}
        />
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a rating card for the overview tab with a light background.
  """
  attr :source, :string, required: true
  attr :value, :any, required: true
  attr :vote_count, :integer, default: nil
  attr :scale, :string, default: nil
  attr :source_name, :string, default: nil, doc: "Optional display name override"
  attr :url, :string, default: nil, doc: "Optional link to the rating source"

  def rating_card(assigns) do
    config =
      Map.get(@icon_config, assigns.source, %{
        slug: "film",
        color: "666666",
        name: "Unknown",
        scale: nil
      })

    scale = assigns.scale || config[:scale]
    display_name = assigns.source_name || config[:name]
    assigns = assign(assigns, config: config, resolved_scale: scale, display_name: display_name)

    ~H"""
    <%= if @url do %>
      <a
        href={@url}
        target="_blank"
        rel="noopener noreferrer"
        class="block text-center p-4 bg-gray-50 rounded-lg hover:bg-gray-100 transition-colors group"
      >
        <div class="flex justify-center mb-2">
          <.rating_icon source={@source} config={@config} variant={:card} />
        </div>
        <div class="text-2xl font-bold text-gray-900 mb-1">
          {format_value(@value, @resolved_scale)}
        </div>
        <div class="text-sm text-gray-500 group-hover:text-blue-600 transition-colors">
          {@display_name} ↗
        </div>
        <%= if @vote_count do %>
          <div class="text-xs text-gray-400 mt-1">
            {format_vote_count(@vote_count)} votes
          </div>
        <% end %>
      </a>
    <% else %>
      <div class="text-center p-4 bg-gray-50 rounded-lg hover:bg-gray-100 transition-colors">
        <div class="flex justify-center mb-2">
          <.rating_icon source={@source} config={@config} variant={:card} />
        </div>
        <div class="text-2xl font-bold text-gray-900 mb-1">
          {format_value(@value, @resolved_scale)}
        </div>
        <div class="text-sm text-gray-500">
          {@display_name}
        </div>
        <%= if @vote_count do %>
          <div class="text-xs text-gray-400 mt-1">
            {format_vote_count(@vote_count)} votes
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  @doc """
  Renders a rating card from an external_rating struct.

  Handles the `Cinegraph.ExternalSources.Rating` struct, automatically
  normalizing the source name and extracting the scale from metadata.
  """
  attr :rating, :map,
    required: true,
    doc: "An external_rating struct with source, value, and metadata"

  attr :imdb_id, :string, default: nil, doc: "IMDb ID for building URL"
  attr :tmdb_id, :integer, default: nil, doc: "TMDb ID for building URL"

  def external_rating_card(assigns) do
    rating = assigns.rating

    source_name =
      rating.metadata["source_name"] || (rating.source && rating.source.name) || "Unknown"

    source_key = normalize_source(source_name)
    scale = rating.metadata["scale"]

    # Build URL based on source
    url = build_rating_url(source_key, assigns.imdb_id, assigns.tmdb_id)

    assigns =
      assign(assigns,
        source_key: source_key,
        scale: scale,
        url: url
      )

    # Don't pass source_name - let rating_card use the human-readable name from @icon_config
    ~H"""
    <.rating_card
      source={@source_key}
      value={@rating.value}
      scale={@scale}
      url={@url}
    />
    """
  end

  @doc """
  Renders a grid of external rating cards from external_ratings list.

  This is a convenience component for the overview tab that handles
  the full list of external_rating structs.
  """
  attr :ratings, :list, required: true, doc: "List of external_rating structs"
  attr :limit, :integer, default: 8, doc: "Maximum number of ratings to display"
  attr :class, :string, default: ""
  attr :movie, :map, default: nil, doc: "Movie struct for building URLs"

  def external_ratings_grid(assigns) do
    imdb_id = if assigns.movie, do: Map.get(assigns.movie, :imdb_id), else: nil
    tmdb_id = if assigns.movie, do: Map.get(assigns.movie, :tmdb_id), else: nil
    assigns = assign(assigns, imdb_id: imdb_id, tmdb_id: tmdb_id)

    ~H"""
    <div class={["grid grid-cols-2 md:grid-cols-4 gap-4", @class]}>
      <%= for rating <- Enum.take(@ratings, @limit) do %>
        <.external_rating_card rating={rating} imdb_id={@imdb_id} tmdb_id={@tmdb_id} />
      <% end %>
    </div>
    """
  end

  # Build URL for rating source based on available IDs
  defp build_rating_url("imdb", imdb_id, _tmdb_id) when is_binary(imdb_id) and imdb_id != "" do
    "https://www.imdb.com/title/#{imdb_id}/"
  end

  defp build_rating_url("tmdb", _imdb_id, tmdb_id) when is_integer(tmdb_id) do
    "https://www.themoviedb.org/movie/#{tmdb_id}"
  end

  defp build_rating_url(_source, _imdb_id, _tmdb_id), do: nil

  @doc """
  Renders a horizontal row of inline rating badges for the hero section.

  Displays all available ratings in a compact, scannable row with icons
  and scores. Designed to be placed prominently under movie details.

  ## Examples

      <.hero_ratings_row movie={@movie} />
  """
  attr :movie, :map, required: true, doc: "The movie struct with omdb_data and external_ratings"
  attr :class, :string, default: ""

  def hero_ratings_row(assigns) do
    # Build list of available ratings from multiple sources (with URLs)
    ratings = build_hero_ratings(assigns.movie)
    assigns = assign(assigns, :ratings, ratings)

    ~H"""
    <%= if length(@ratings) > 0 do %>
      <div class={["flex flex-wrap items-center gap-2", @class]}>
        <%= for rating <- @ratings do %>
          <.inline_rating_badge source={rating.source} value={rating.value} url={rating[:url]} />
        <% end %>
      </div>
    <% end %>
    """
  end

  @doc """
  Renders a branded rating pill with solid background and brand colors.

  Uses solid brand-colored backgrounds for high visibility and readability
  on dark hero sections. Each rating source has distinct visual identity.
  """
  attr :source, :string, required: true
  attr :value, :any, required: true
  attr :url, :string, default: nil
  attr :class, :string, default: ""

  def inline_rating_badge(assigns) do
    config =
      Map.get(@icon_config, assigns.source, %{
        slug: "film",
        color: "666666",
        name: "Unknown",
        scale: nil
      })

    assigns = assign(assigns, config: config)

    # Compact horizontal with dark glass background + colored icon + hover popover
    ~H"""
    <div class={["relative group", @class]}>
      <%= if @url do %>
        <a
          href={@url}
          target="_blank"
          rel="noopener noreferrer"
          class={[
            "inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full",
            "bg-gray-900/80 backdrop-blur-sm",
            "hover:bg-gray-900 transition-all duration-200"
          ]}
        >
          <.rating_icon_inline config={@config} />
          <span class="text-white font-semibold text-xs">
            {format_value(@value, @config.scale)}
          </span>
        </a>
      <% else %>
        <div class={[
          "inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full cursor-help",
          "bg-gray-900/80 backdrop-blur-sm",
          "group-hover:bg-gray-900 transition-all duration-200"
        ]}>
          <.rating_icon_inline config={@config} />
          <span class="text-white font-semibold text-xs">
            {format_value(@value, @config.scale)}
          </span>
        </div>
      <% end %>
      <!-- Hover Popover -->
      <div class="hidden group-hover:block absolute z-20 w-64 p-3 mt-2 bg-gray-900 text-white rounded-lg shadow-xl left-0 top-full">
        <div class="flex items-center gap-2 mb-2">
          <%= case @config[:icon_type] do %>
            <% :popcorn -> %>
              <span class="text-lg">🍿</span>
            <% :tomato -> %>
              <span class="text-lg">🍅</span>
            <% _ -> %>
              <img
                src={"https://cdn.simpleicons.org/#{@config.slug}/#{@config.color}"}
                alt={@config.name}
                class="h-5 w-5"
                loading="lazy"
              />
          <% end %>
          <span class="font-bold text-sm">{@config.name}</span>
        </div>
        <div class="text-xl font-bold mb-2">{format_value(@value, @config.scale)}</div>
        <p class="text-white/70 text-xs leading-relaxed">
          {@config[:description] || "Rating from #{@config.name}"}
        </p>
        <%= if @url do %>
          <p class="text-blue-400 text-xs mt-2">Click to view on {@config.name} →</p>
        <% end %>
      </div>
    </div>
    """
  end

  # Helper for inline badge icon
  defp rating_icon_inline(assigns) do
    ~H"""
    <%= case @config[:icon_type] do %>
      <% :popcorn -> %>
        <span class="text-xs">🍿</span>
      <% :tomato -> %>
        <span class="text-xs">🍅</span>
      <% _ -> %>
        <img
          src={"https://cdn.simpleicons.org/#{@config.slug}/#{@config.color}"}
          alt={@config.name}
          class="h-3.5 w-3.5"
          loading="lazy"
        />
    <% end %>
    """
  end

  # Build hero ratings from movie data (with URLs where available)
  defp build_hero_ratings(movie) do
    ratings = []

    # Get external IDs for building URLs
    imdb_id = Map.get(movie, :imdb_id)
    tmdb_id = Map.get(movie, :tmdb_id)

    # IMDb from omdb_data
    ratings =
      case get_in(movie.omdb_data || %{}, ["imdbRating"]) do
        nil -> ratings
        "N/A" -> ratings
        value ->
          url = if imdb_id, do: "https://www.imdb.com/title/#{imdb_id}/", else: nil
          ratings ++ [%{source: "imdb", value: value, url: url}]
      end

    # Metacritic from omdb_data (no reliable URL without their slug)
    ratings =
      case get_in(movie.omdb_data || %{}, ["Metascore"]) do
        nil -> ratings
        "N/A" -> ratings
        value -> ratings ++ [%{source: "metacritic", value: value, url: nil}]
      end

    # Rotten Tomatoes from omdb_data Ratings array (no reliable URL without their slug)
    ratings =
      case find_omdb_rating(movie.omdb_data, "Rotten Tomatoes") do
        nil -> ratings
        value -> ratings ++ [%{source: "rotten_tomatoes", value: parse_rt_value(value), url: nil}]
      end

    # TMDb from tmdb_data
    ratings =
      case get_in(movie.tmdb_data || %{}, ["vote_average"]) do
        nil -> ratings
        0 -> ratings
        value when value == 0.0 -> ratings
        value ->
          url = if tmdb_id, do: "https://www.themoviedb.org/movie/#{tmdb_id}", else: nil
          ratings ++ [%{source: "tmdb", value: value, url: url}]
      end

    # Add from external_ratings if available (for Letterboxd, etc.)
    ratings =
      if Map.has_key?(movie, :external_ratings) && is_list(movie.external_ratings) do
        Enum.reduce(movie.external_ratings, ratings, fn rating, acc ->
          source_name =
            rating.metadata["source_name"] ||
              (rating.source && rating.source.name) ||
              "Unknown"

          source_key = normalize_source(source_name)

          # Skip if we already have this source from omdb/tmdb
          if Enum.any?(acc, fn r -> r.source == source_key end) do
            acc
          else
            acc ++ [%{source: source_key, value: rating.value}]
          end
        end)
      else
        ratings
      end

    ratings
  end

  defp find_omdb_rating(nil, _source), do: nil

  defp find_omdb_rating(omdb_data, source) do
    case omdb_data["Ratings"] do
      nil ->
        nil

      ratings when is_list(ratings) ->
        Enum.find_value(ratings, fn
          %{"Source" => ^source, "Value" => value} -> value
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp parse_rt_value(value) when is_binary(value) do
    # Handle "92%" format
    case Integer.parse(String.replace(value, "%", "")) do
      {num, _} -> num
      :error -> value
    end
  end

  defp parse_rt_value(value), do: value

  # Private helper functions

  defp badge_classes(:hero, extra) do
    [
      "inline-flex items-center gap-3 px-4 py-3 rounded-xl bg-white/10 backdrop-blur-sm",
      "border border-white/20 hover:bg-white/15 transition-colors",
      extra
    ]
  end

  defp badge_classes(:compact, extra) do
    ["inline-flex items-center gap-2 px-2 py-1 rounded-lg bg-white/10", extra]
  end

  defp badge_classes(:default, extra) do
    ["inline-flex items-center gap-2 px-3 py-2 rounded-lg bg-white/10", extra]
  end

  defp value_container_classes(:hero), do: "text-center"
  defp value_container_classes(:compact), do: "text-center"
  defp value_container_classes(:default), do: "text-center"

  defp value_classes(:hero), do: "text-xl font-bold text-white"
  defp value_classes(:compact), do: "text-sm font-bold text-white"
  defp value_classes(:default), do: "font-bold text-white"

  defp label_classes(:hero), do: "text-xs text-white/60"
  defp label_classes(:compact), do: "text-xs text-white/60 hidden"
  defp label_classes(:default), do: "text-xs text-white/60"

  defp icon_classes(:hero), do: "h-8 w-8"
  defp icon_classes(:card), do: "h-8 w-8"
  defp icon_classes(:inline), do: "h-6 w-6"
  defp icon_classes(:compact), do: "h-4 w-4"
  defp icon_classes(:default), do: "h-5 w-5"

  defp icon_container_classes(:hero), do: "flex items-center justify-center w-8 h-8"
  defp icon_container_classes(:card), do: "flex items-center justify-center w-8 h-8"
  defp icon_container_classes(:inline), do: "flex items-center justify-center w-6 h-6"
  defp icon_container_classes(:compact), do: "flex items-center justify-center w-4 h-4"
  defp icon_container_classes(:default), do: "flex items-center justify-center w-5 h-5"

  defp emoji_icon_classes(:hero), do: "text-2xl"
  defp emoji_icon_classes(:card), do: "text-2xl"
  defp emoji_icon_classes(:inline), do: "text-xl"
  defp emoji_icon_classes(:compact), do: "text-sm"
  defp emoji_icon_classes(:default), do: "text-lg"

  defp format_value(value, scale) when is_binary(value) do
    # Handle string values like "7.8" or "N/A"
    case Float.parse(value) do
      {num, _} -> format_value(num, scale)
      :error -> value
    end
  end

  defp format_value(value, "0-100") when is_number(value) do
    "#{round(value)}%"
  end

  defp format_value(value, "0-10") when is_number(value) do
    formatted =
      if is_float(value), do: :erlang.float_to_binary(value, decimals: 1), else: "#{value}"

    "#{formatted}/10"
  end

  defp format_value(value, "0-5") when is_number(value) do
    formatted =
      if is_float(value), do: :erlang.float_to_binary(value, decimals: 1), else: "#{value}"

    "#{formatted}/5"
  end

  defp format_value(value, _scale) when is_number(value) do
    if is_float(value) do
      :erlang.float_to_binary(value, decimals: 1)
    else
      "#{value}"
    end
  end

  defp format_value(value, _scale), do: "#{value}"

  defp format_vote_count(count) when count >= 1_000_000 do
    "#{Float.round(count / 1_000_000, 1)}M"
  end

  defp format_vote_count(count) when count >= 1_000 do
    "#{Float.round(count / 1_000, 1)}K"
  end

  defp format_vote_count(count), do: "#{count}"
end
