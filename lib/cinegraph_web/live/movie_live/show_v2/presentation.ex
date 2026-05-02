defmodule CinegraphWeb.MovieLive.ShowV2.Presentation do
  @moduledoc false
  import CinegraphWeb.PersonHelpers, only: [person_slug_or_id: 1]
  alias CinegraphWeb.Helpers.UrlHelpers
  alias CinegraphWeb.MovieLive.CollaborationHelpers
  @dept_priority ~w(Directing Writing Camera Editing Sound Production Art)
  @country_priority ~w(US GB FR DE JP KR IT ES CA AU IN BR MX)

  def tmdb_url(nil, _), do: nil
  def tmdb_url("", _), do: nil
  def tmdb_url("/" <> _ = path, size), do: "https://image.tmdb.org/t/p/#{size}#{path}"
  def tmdb_url(path, size), do: "https://image.tmdb.org/t/p/#{size}/#{path}"

  def year_of(%Date{year: y}), do: y
  def year_of(_), do: nil

  def format_runtime(nil), do: nil

  def format_runtime(min) when is_integer(min) do
    h = div(min, 60)
    m = rem(min, 60)

    cond do
      h > 0 and m > 0 -> "#{h}h #{m}m"
      h > 0 -> "#{h}h"
      true -> "#{m}m"
    end
  end

  def content_rating(%{omdb_data: %{"Rated" => r}}) when is_binary(r) and r != "" and r != "N/A",
    do: r

  def content_rating(_), do: nil

  def disparity_label("critics_darling"), do: "Critics' Darling"
  def disparity_label("peoples_champion"), do: "People's Champion"
  def disparity_label("polarizer"), do: "Polarizer"
  def disparity_label(_), do: nil

  def disparity_summary(disparity_data, scores) do
    case disparity_data[:disparity_category] do
      "critics_darling" ->
        gap = ((scores[:critics] || 0) - (scores[:mob] || 0)) |> Float.round(1)
        "critics +#{gap} over audience"

      "peoples_champion" ->
        gap = ((scores[:mob] || 0) - (scores[:critics] || 0)) |> Float.round(1)
        "audience +#{gap} over critics"

      "polarizer" ->
        "audience and critics divided"

      _ ->
        nil
    end
  end

  def truncate_words(text, n) when is_binary(text) do
    words = String.split(text)

    if length(words) <= n,
      do: {text, false},
      else: {words |> Enum.take(n) |> Enum.join(" "), true}
  end

  def truncate_words(_, _), do: {"", false}

  def format_money(nil), do: nil
  def format_money(0), do: nil

  def format_money(n) when is_number(n) and n >= 1_000_000_000,
    do: "$#{Float.round(n / 1_000_000_000, 1)}B"

  def format_money(n) when is_number(n) and n >= 1_000_000,
    do: "$#{Float.round(n / 1_000_000, 1)}M"

  def format_money(n) when is_number(n), do: "$#{n}"

  def rating_value(ratings, source_key, type \\ "rating_average") do
    Enum.find(ratings, fn r ->
      key =
        case r[:source] do
          %{source_key: sk} -> sk
          %{name: n} -> n
          _ -> nil
        end

      key == source_key and r[:metric_type] == type
    end)
  end

  def pluralize_str(1, w), do: w
  def pluralize_str(_, w), do: w <> "s"

  def count_award_wins(noms) when is_list(noms) do
    Enum.reduce(noms, 0, fn org, acc ->
      acc + Enum.count(Map.get(org, :nominations) || [], fn n -> Map.get(n, :won) == true end)
    end)
  end

  def count_award_wins(_), do: 0

  def count_award_nominations(noms) when is_list(noms) do
    Enum.reduce(noms, 0, fn org, acc ->
      acc + (Map.get(org, :total_nominations) || length(Map.get(org, :nominations) || []))
    end)
  end

  def count_award_nominations(_), do: 0

  def render_nominations(noms) when is_list(noms) do
    Enum.map(noms, fn n ->
      person_name =
        case n[:person] do
          %{name: name} -> name
          _ -> n[:details]["nominee_names"]
        end

      %{
        category: Map.get(n, :category_name) || Map.get(n, :category) || "—",
        year: Map.get(n, :ceremony_year),
        won: !!Map.get(n, :won),
        person_name: person_name,
        film_title: nil,
        film_href: nil
      }
    end)
  end

  def render_nominations(_), do: []

  def film_card_shape(movie) do
    href = UrlHelpers.movie_href(movie.slug, movie.id)

    %{
      id: movie.id,
      title: movie.title,
      year: year_of(movie.release_date),
      score: nil,
      poster_url: tmdb_url(movie.poster_path, "w500"),
      href: href
    }
  end

  def related_card_shape(rel) do
    href = UrlHelpers.movie_href(rel[:slug], rel.id)

    %{
      id: rel.id,
      title: rel.title,
      year: year_of(rel[:release_date]),
      score: nil,
      poster_url: tmdb_url(rel[:poster_path], "w500"),
      href: href,
      reason: rel[:connection_reason]
    }
  end

  def cast_credit_shape(credit) do
    %{
      name: credit.person.name,
      character: credit.character,
      avatar_url: tmdb_url(credit.person.profile_path, "w185"),
      href: person_href(credit.person)
    }
  end

  def crew_credit_shape(c) do
    %{
      name: c.person.name,
      job: c.job,
      avatar_url: tmdb_url(c.person.profile_path, "w185"),
      href: person_href(c.person)
    }
  end

  def person_href(person), do: "/people/#{person_slug_or_id(person)}"

  def prioritize_releases(releases) do
    releases
    |> Enum.group_by(& &1.country_code)
    |> Enum.map(fn {country, recs} ->
      earliest =
        recs
        |> Enum.reject(&is_nil(&1.release_date))
        |> Enum.min_by(& &1.release_date, NaiveDateTime, fn -> nil end)

      cert = Enum.find_value(recs, &(&1.certification not in [nil, ""] && &1.certification))

      %{
        country_code: country,
        release_date: earliest && earliest.release_date,
        certification: cert
      }
    end)
    |> Enum.sort_by(fn r ->
      case Enum.find_index(@country_priority, &(&1 == r.country_code)) do
        nil -> {1, r.country_code}
        i -> {0, i}
      end
    end)
  end

  def crew_by_department(crew) do
    crew
    |> Enum.reject(&(&1.department in [nil, ""]))
    |> Enum.group_by(& &1.department)
    |> Enum.sort_by(fn {d, _} ->
      case Enum.find_index(@dept_priority, &(&1 == d)) do
        nil -> {1, d}
        i -> {0, i}
      end
    end)
  end

  def collab_shape(c) do
    person_a = c[:person_a]
    person_b = c[:person_b]

    %{
      person_a: person_name(person_a),
      person_b: person_name(person_b),
      avatar_a: tmdb_url(person_profile_path(person_a), "w185"),
      avatar_b: tmdb_url(person_profile_path(person_b), "w185"),
      films_together:
        c[:films_together] || length(c[:movies] || []) || c[:collaboration_count] ||
          c[:total_collaborations] || 0,
      strength:
        cond do
          (c[:films_together] || c[:collaboration_count] || 0) >= 10 -> :very_strong
          (c[:films_together] || c[:collaboration_count] || 0) >= 5 -> :strong
          true -> :moderate
        end,
      year_range: c[:year_range],
      avg_score: c[:avg_movie_rating],
      total_revenue: c[:total_revenue],
      movies: c[:movies],
      href: CollaborationHelpers.collaboration_search_href(c)
    }
  end

  defp person_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp person_name(_), do: "Unknown"
  defp person_profile_path(%{profile_path: path}), do: path
  defp person_profile_path(_), do: nil

  def director_names(directors), do: directors |> Enum.map(&director_name/1) |> Enum.join(" & ")

  defp director_name(%{person: person}), do: person_name(person)
  defp director_name(_), do: person_name(nil)

  def omdb_awards(%{omdb_data: %{"Awards" => a}}) when is_binary(a) and a != "" and a != "N/A",
    do: a

  def omdb_awards(_), do: nil

  def top_org_names(noms) when is_list(noms) do
    noms
    |> Enum.map(& &1[:organization_name])
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.take(3)
    |> Enum.join(" · ")
  end

  def top_org_names(_), do: nil

  def top_canon_authorities(lists) when is_list(lists) do
    lists
    |> Enum.map(&(&1.short_name || &1.list_name))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.take(3)
    |> Enum.join(" · ")
  end

  def top_canon_authorities(_), do: nil

  defdelegate list_appearance_href(list),
    to: CinegraphWeb.MovieLive.ShowV2.ListAppearance,
    as: :href

  defdelegate list_appearance_title(list),
    to: CinegraphWeb.MovieLive.ShowV2.ListAppearance,
    as: :title

  defdelegate list_appearance_eyebrow(list),
    to: CinegraphWeb.MovieLive.ShowV2.ListAppearance,
    as: :eyebrow

  defdelegate list_appearance_rank(list),
    to: CinegraphWeb.MovieLive.ShowV2.ListAppearance,
    as: :rank

  defdelegate list_appearance_image(list),
    to: CinegraphWeb.MovieLive.ShowV2.ListAppearance,
    as: :image

  defdelegate list_appearance_initials(list),
    to: CinegraphWeb.MovieLive.ShowV2.ListAppearance,
    as: :initials

  defdelegate list_appearance_visual_class(list),
    to: CinegraphWeb.MovieLive.ShowV2.ListAppearance,
    as: :visual_class

  def top_festival_win(noms) when is_list(noms) do
    Enum.find_value(noms, fn org ->
      win =
        Enum.find(org[:nominations] || [], fn n ->
          n[:won] == true
        end)

      if win do
        %{
          org: org[:organization_name],
          year: win[:ceremony_year],
          category: win[:category_name] || win[:category]
        }
      end
    end)
  end

  def top_festival_win(_), do: nil

  def top_collab_pairing(key_collabs) do
    pair = List.first(key_collabs[:notable_collaborations] || [])

    if pair, do: "#{pair.person_a.name} + #{pair.person_b.name}", else: nil
  end
end
