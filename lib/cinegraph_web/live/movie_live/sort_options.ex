defmodule CinegraphWeb.MovieLive.SortOptions do
  @moduledoc """
  Shared sort-option catalog for the movies discovery pages (`/movies`, `/movies-v2`).

  Both LiveViews use the same set of static sort criteria (Basic / Ratings / By Lens)
  plus a dynamic group of Scored Presets pulled from `Cinegraph.Metrics.ScoringService`.
  """

  alias Cinegraph.Metrics.ScoringService

  @static_options [
    %{value: "release_date", label: "📅 Release Date", group: "Basic"},
    %{value: "title", label: "🔤 Title", group: "Basic"},
    %{value: "runtime", label: "⏱️ Runtime", group: "Basic"},
    %{value: "rating", label: "⭐ Rating", group: "Ratings"},
    %{value: "popularity", label: "🔥 Popularity", group: "Ratings"},
    %{value: "score", label: "⭐ Top Rated", group: "Ratings"},
    %{value: "mob", label: "👥 The Mob", group: "By Lens"},
    %{value: "critics", label: "🎭 The Critics", group: "By Lens"},
    %{value: "festival_recognition", label: "🏆 The Insiders", group: "By Lens"},
    %{value: "time_machine", label: "⏳ The Time Machine", group: "By Lens"},
    %{value: "auteurs", label: "🎬 The Auteurs", group: "By Lens"}
  ]

  @lens_keys ~w(mob critics festival_recognition time_machine auteurs)

  @doc """
  Returns the full sort-options catalog, including dynamic Scored Preset entries
  appended after the static groups.
  """
  @spec all() :: [map()]
  def all, do: @static_options ++ preset_options()

  @doc """
  Returns the static sort options only (no DB hit).
  """
  @spec static() :: [map()]
  def static, do: @static_options

  @doc """
  Returns the dynamic Scored Preset sort options, derived from the active scoring
  profiles in `Cinegraph.Metrics.ScoringService`. Each entry has `:slug`, `:name`.
  """
  @spec preset_options() :: [map()]
  def preset_options do
    load_weight_presets()
    |> Enum.map(fn p -> %{value: p.slug, label: p.name, group: "Scored Presets"} end)
  end

  @doc "Loads weight-preset slug/name pairs (used for the Scored Presets sort group)."
  @spec load_weight_presets() :: [%{slug: String.t(), name: String.t()}]
  def load_weight_presets do
    ScoringService.get_all_profiles()
    |> Enum.map(fn p -> %{slug: name_to_slug(p.name), name: p.name} end)
  end

  @doc """
  Returns the list of preset slugs currently registered.
  """
  @spec preset_slugs() :: [String.t()]
  def preset_slugs, do: load_weight_presets() |> Enum.map(& &1.slug)

  @doc """
  Returns true when the given sort criterion (without `_asc`/`_desc` suffix) refers
  to a Scored Preset rather than a static option.
  """
  @spec preset?(String.t()) :: boolean()
  def preset?(criteria) when is_binary(criteria), do: criteria in preset_slugs()
  def preset?(_), do: false

  @doc """
  Returns true when the given sort criterion is a By-Lens sort
  (mob, critics, festival_recognition, time_machine, auteurs).
  """
  @spec lens?(String.t()) :: boolean()
  def lens?(criteria) when is_binary(criteria), do: criteria in @lens_keys
  def lens?(_), do: false

  @doc """
  Returns the active "lens key" for a sort criterion — either the lens name
  (`"mob"`, `"critics"`, ...) or `:preset` for a Scored Preset, or `nil` when the
  sort is a basic/rating field that does not warrant a score badge.
  """
  @spec active_lens_key(String.t()) :: String.t() | :preset | nil
  def active_lens_key(criteria) do
    cond do
      lens?(criteria) -> criteria
      preset?(criteria) -> :preset
      true -> nil
    end
  end

  @doc "Lowercased, underscored slug for a profile name."
  @spec name_to_slug(String.t()) :: String.t()
  def name_to_slug(name), do: name |> String.downcase() |> String.replace(" ", "_")
end
