defmodule CinegraphWeb.RatingComponents do
  @moduledoc """
  Provides branded rating badge components using Simple Icons.

  Rating sources display with official brand icons and colors from
  the Simple Icons library (https://simpleicons.org).
  """
  use Phoenix.Component

  @icon_config %{
    "imdb" => %{slug: "imdb", color: "F5C518", name: "IMDb", scale: "0-10"},
    "tmdb" => %{slug: "themoviedatabase", color: "01D277", name: "TMDb", scale: "0-10"},
    "rotten_tomatoes" => %{
      slug: "rottentomatoes",
      color: "FA320A",
      name: "Tomatometer",
      scale: "0-100"
    },
    "rotten_tomatoes_audience" => %{
      slug: "rottentomatoes",
      color: "FA320A",
      name: "Audience",
      scale: "0-100",
      icon_type: :popcorn
    },
    "metacritic" => %{slug: "metacritic", color: "FFCC34", name: "Metacritic", scale: "0-100"},
    "letterboxd" => %{slug: "letterboxd", color: "00D735", name: "Letterboxd", scale: "0-5"}
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
    <%= if @config[:icon_type] == :popcorn do %>
      <div class={icon_container_classes(@variant)}>
        <span class={popcorn_icon_classes(@variant)}>🍿</span>
      </div>
    <% else %>
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

  def external_rating_card(assigns) do
    rating = assigns.rating

    source_name =
      rating.metadata["source_name"] || (rating.source && rating.source.name) || "Unknown"

    source_key = normalize_source(source_name)
    scale = rating.metadata["scale"]

    assigns =
      assign(assigns,
        source_key: source_key,
        source_name: source_name,
        scale: scale
      )

    ~H"""
    <.rating_card
      source={@source_key}
      value={@rating.value}
      scale={@scale}
      source_name={@source_name}
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

  def external_ratings_grid(assigns) do
    ~H"""
    <div class={["grid grid-cols-2 md:grid-cols-4 gap-4", @class]}>
      <%= for rating <- Enum.take(@ratings, @limit) do %>
        <.external_rating_card rating={rating} />
      <% end %>
    </div>
    """
  end

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
  defp icon_classes(:compact), do: "h-4 w-4"
  defp icon_classes(:default), do: "h-5 w-5"

  defp icon_container_classes(:hero), do: "flex items-center justify-center w-8 h-8"
  defp icon_container_classes(:card), do: "flex items-center justify-center w-8 h-8"
  defp icon_container_classes(:compact), do: "flex items-center justify-center w-4 h-4"
  defp icon_container_classes(:default), do: "flex items-center justify-center w-5 h-5"

  defp popcorn_icon_classes(:hero), do: "text-2xl"
  defp popcorn_icon_classes(:card), do: "text-2xl"
  defp popcorn_icon_classes(:compact), do: "text-sm"
  defp popcorn_icon_classes(:default), do: "text-lg"

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
