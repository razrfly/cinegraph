defmodule Cinegraph.Homepage do
  @moduledoc """
  Data snapshot for the public Cinegraph home page.

  The home page is intentionally deterministic per UTC day. Expensive-ish query
  groups are cached, while activity keeps using the health activity cache.
  """

  import Ecto.Query
  require Logger

  alias Cinegraph.Collaborations.CollaborationDetail
  alias Cinegraph.Events.FestivalDate
  alias Cinegraph.Health.Activity
  alias Cinegraph.Movies
  alias Cinegraph.Movies.{Movie, MovieList, MovieLists, MovieScoreCache, Person}
  alias Cinegraph.Repo

  @daily_ttl :timer.hours(24)
  @hourly_ttl :timer.hours(1)
  @cache_name :movies_cache
  @lens_order [
    %{
      key: :mob,
      field: :mob_score,
      title: "The Mob",
      sort: "mob_desc",
      description: "Audience consensus from IMDb, TMDb, and Rotten Tomatoes audience ratings."
    },
    %{
      key: :critics,
      field: :critics_score,
      title: "The Critics",
      sort: "critics_desc",
      description: "Professional review signal from Rotten Tomatoes and Metacritic."
    },
    %{
      key: :festival_recognition,
      field: :festival_recognition_score,
      title: "The Inner Circle",
      sort: "festival_recognition_desc",
      description: "Festival wins and nominations across major industry bodies."
    },
    %{
      key: :time_machine,
      field: :time_machine_score,
      title: "The Time Machine",
      sort: "time_machine_desc",
      description: "Long-term staying power from canon lists and cultural memory."
    },
    %{
      key: :auteurs,
      field: :auteurs_score,
      title: "The Auteurs",
      sort: "auteurs_desc",
      description: "Director, cast, and crew quality across broader film achievements."
    },
    %{
      key: :box_office,
      field: :box_office_score,
      title: "The Box Office",
      sort: "box_office_desc",
      description: "Commercial performance from revenue and return on investment."
    }
  ]

  @doc "Returns the full data snapshot for the v2 public home page."
  def snapshot(date \\ Date.utc_today()) do
    %{
      date: date,
      hero: hero(date),
      corpus_tagline: hourly(:corpus_tagline, date, &corpus_tagline/0),
      spotlight: daily(:spotlight, date, fn -> spotlight(date) end),
      canon_agreement: daily(:canon_agreement, date, fn -> canon_agreement(date) end),
      lens: daily(:lens, date, fn -> lens_spotlight(date) end),
      disparity: daily(:disparity, date, fn -> disparity_cards(date) end),
      six_degrees: daily(:six_degrees, date, fn -> six_degrees_teaser(date) end),
      theaters: hourly(:theaters, date, fn -> theater_movies(date) end),
      festival_pulse: daily(:festival_pulse, date, fn -> festival_pulse(date) end),
      ceremonies: daily(:ceremonies, date, fn -> recent_ceremonies(date) end),
      popular_lists: daily(:popular_lists, date, &popular_lists/0),
      activity: activity_rows()
    }
  end

  @doc """
  The 6-lens definitions used by the trust badge under the hero. Each entry has
  `key`, `field`, `title`, `sort` (used in /movies?sort=...), `description`,
  and `accent` (a tone key consumable by `n_pill`).
  """
  def lens_definitions do
    @lens_order
    |> Enum.map(fn lens ->
      Map.put(lens, :accent, lens_accent(lens.key))
    end)
  end

  defp lens_accent(:mob), do: "ink"
  defp lens_accent(:critics), do: "blue"
  defp lens_accent(:festival_recognition), do: "amber"
  defp lens_accent(:time_machine), do: "neutral"
  defp lens_accent(:auteurs), do: "red"
  defp lens_accent(:box_office), do: "green"
  defp lens_accent(_), do: "neutral"

  defp hero(date) do
    %{
      eyebrow: "The video store clerk for the streaming era",
      title: "What's worth watching tonight?",
      subtitle:
        "We score every film six different ways — by critics, audiences, festivals, the canon, the people who made it, and the box office — so you can find what's good by your definition of good.",
      cta_label: "Ask the Video Clerk",
      cta_href: "/video-clerk",
      backdrop_url: hero_backdrop(date)
    }
  end

  defp hero_backdrop(date) do
    case daily(:hero_backdrop, date, fn -> fetch_hero_backdrop(date) end) do
      url when is_binary(url) -> url
      _ -> nil
    end
  end

  defp fetch_hero_backdrop(date) do
    movie =
      from(m in Movies.feature_film_query(),
        left_join: s in assoc(m, :score_cache),
        where: not is_nil(m.backdrop_path),
        where: not is_nil(s.overall_score),
        order_by: [desc: s.overall_score, asc: m.id],
        preload: [score_cache: s],
        limit: 50
      )
      |> Repo.replica().all()
      |> pick(date, :hero_backdrop)

    movie && Movie.backdrop_url(movie, "w1280")
  rescue
    exception ->
      log_homepage_error(:fetch_hero_backdrop, exception, __STACKTRACE__)
      nil
  end

  defp corpus_tagline do
    count = feature_film_count()

    %{
      count: count,
      copy: "#{format_count(count)} films scored across six dimensions — and counting."
    }
  rescue
    exception ->
      log_homepage_error(:corpus_tagline, exception, __STACKTRACE__)
      %{count: 0, copy: "Films scored across six dimensions — and counting."}
  end

  defp feature_film_count do
    Movies.feature_film_query()
    |> Repo.replica().aggregate(:count, :id)
  end

  defp spotlight(date) do
    candidates =
      []
      |> add_if_present(birthday_spotlight(date))
      |> add_if_present(premiered_spotlight(date))
      |> add_if_present(canon_spotlight(date))
      |> add_if_present(festival_today_spotlight(date))

    pick(candidates, date, :spotlight) ||
      %{
        type: "Today on Cinegraph",
        title: "The graph is warming up",
        subtitle:
          "As data imports finish, this space will rotate through films, people, lists, and festivals.",
        href: "/movies",
        image_url: nil,
        meta: ["Dynamic daily spotlight"]
      }
  end

  defp birthday_spotlight(%Date{month: month, day: day}) do
    person =
      from(p in Person,
        where:
          fragment(
            "EXTRACT(MONTH FROM ?) = ? AND EXTRACT(DAY FROM ?) = ?",
            p.birthday,
            ^month,
            p.birthday,
            ^day
          ),
        where: p.adult == false,
        order_by: [desc: p.popularity, asc: p.id],
        limit: 1
      )
      |> Repo.replica().one()

    if person do
      %{
        type: "Born today",
        title: person.name,
        subtitle: "A film-graph connector with a birthday today.",
        href: "/people/#{person.slug || person.id}",
        image_url: Person.profile_url(person, "w342"),
        meta: compact(["#{person.known_for_department || "Film"}", date_year(person.birthday)])
      }
    end
  end

  defp premiered_spotlight(%Date{month: month, day: day}) do
    movie =
      from(m in Movies.feature_film_query(),
        left_join: s in assoc(m, :score_cache),
        where:
          fragment(
            "EXTRACT(MONTH FROM ?) = ? AND EXTRACT(DAY FROM ?) = ?",
            m.release_date,
            ^month,
            m.release_date,
            ^day
          ),
        order_by: [desc_nulls_last: s.overall_score, asc: m.id],
        preload: [score_cache: s],
        limit: 1
      )
      |> Repo.replica().one()

    if movie do
      year = date_year(movie.release_date)

      %{
        type: "Premiered today",
        title: movie.title,
        subtitle:
          if(year, do: "Released on this date in #{year}.", else: "Released on this date."),
        href: movie_href(movie),
        image_url: Movie.poster_url(movie, "w342"),
        meta:
          compact([
            score_label(movie.score_cache),
            "#{canonical_count(movie)}/#{max(active_list_count(), 1)} lists"
          ])
      }
    end
  end

  defp canon_spotlight(date) do
    case canon_agreement(date) do
      [film | _] ->
        %{
          type: "Cross-canon spotlight",
          title: film.title,
          subtitle: "One of today's films with broad canonical agreement.",
          href: film.href,
          image_url: film.poster_url,
          meta: [film.reason, score_label(film)]
        }

      _ ->
        nil
    end
  end

  defp festival_today_spotlight(date) do
    festival =
      from(d in FestivalDate,
        join: e in assoc(d, :festival_event),
        where: e.active == true,
        where: not is_nil(d.start_date) and not is_nil(d.end_date),
        where: d.start_date <= ^date and d.end_date >= ^date,
        order_by: [asc: d.start_date],
        preload: [festival_event: e],
        limit: 1
      )
      |> Repo.replica().one()

    if festival do
      event = festival.festival_event

      %{
        type: "Festival today",
        title: "#{event.name} #{festival.year}",
        subtitle: festival_status_copy(festival, date),
        href: "/awards/#{event.source_key}",
        image_url: nil,
        meta: compact([event.country, festival.status])
      }
    end
  end

  defp canon_agreement(date) do
    candidates =
      from(m in Movies.feature_film_query(),
        left_join: s in assoc(m, :score_cache),
        where: fragment("? != '{}'::jsonb", m.canonical_sources),
        order_by: [desc_nulls_last: s.overall_score, asc: m.id],
        preload: [score_cache: s],
        limit: 500
      )
      |> Repo.replica().all()
      |> Enum.sort_by(fn movie ->
        {-canonical_count(movie), -(score_from(movie.score_cache, :overall_score) || 0), movie.id}
      end)

    pool = pick_canon_pool(candidates)

    result =
      pool
      |> rotate(date, :canon_agreement)
      |> Enum.take(8)

    if length(result) >= 8 do
      Enum.map(result, fn movie ->
        film_card(movie, lens_key: :time_machine, reason: canon_reason(canonical_count(movie)))
      end)
    else
      []
    end
  rescue
    exception ->
      log_homepage_error(:canon_agreement, exception, __STACKTRACE__)
      []
  end

  defp pick_canon_pool(candidates) do
    strong = candidates |> Enum.filter(&(canonical_count(&1) >= 5)) |> Enum.take(50)
    moderate = candidates |> Enum.filter(&(canonical_count(&1) >= 3)) |> Enum.take(50)

    cond do
      length(strong) >= 8 -> strong
      length(moderate) >= 8 -> moderate
      true -> []
    end
  end

  defp canon_reason(1), do: "in 1 list"
  defp canon_reason(n) when is_integer(n) and n > 1, do: "in #{n} lists"
  defp canon_reason(_), do: nil

  defp lens_spotlight(date) do
    lens = Enum.at(@lens_order, rem(Date.day_of_year(date) - 1, length(@lens_order)))
    field = lens.field

    movies =
      from(m in Movies.feature_film_query(),
        join: s in assoc(m, :score_cache),
        where: not is_nil(field(s, ^field)),
        order_by: [
          desc: field(s, ^field),
          desc_nulls_last: s.overall_score,
          desc_nulls_last: m.release_date,
          asc: m.id
        ],
        preload: [score_cache: s],
        limit: 25
      )
      |> Repo.replica().all()
      |> Enum.take(5)

    %{
      lens: lens,
      href: "/movies?sort=#{lens.sort}",
      movies: Enum.map(movies, &film_card(&1, lens_key: lens.key, score_field: field))
    }
  rescue
    exception ->
      log_homepage_error(:lens_spotlight, exception, __STACKTRACE__)
      %{lens: List.first(@lens_order), href: "/movies", movies: []}
  end

  defp disparity_cards(date) do
    [
      disparity_card(
        "critics_darling",
        "Critics' Darlings",
        "High critics, lower audience heat",
        date
      ),
      disparity_card(
        "peoples_champion",
        "People's Champions",
        "Audience favorites critics underrate",
        date
      ),
      disparity_card("polarizer", "The Polarizers", "The biggest agreement gaps", date)
    ]
  end

  defp disparity_card(category, title, subtitle, date) do
    candidates = Movies.list_movies_by_disparity_category(category, limit: 50)

    # Prefer movies that have both scores populated so the displayed
    # "critics X · audience Y" line never reads 0.0. Fall back to the raw
    # pool if nothing meets that bar.
    clean = Enum.filter(candidates, &both_disparity_scores_present?/1)
    pool = if clean == [], do: candidates, else: clean

    movie = pick(pool, date, {:disparity, category})

    %{
      title: title,
      subtitle: subtitle,
      href: "/explore/disparity?tab=#{category}",
      movie: movie && film_card(movie),
      stat: disparity_stat(movie && movie.score_cache)
    }
  rescue
    exception ->
      log_homepage_error(:disparity_card, exception, __STACKTRACE__)

      %{
        title: title,
        subtitle: subtitle,
        href: "/explore/disparity?tab=#{category}",
        movie: nil,
        stat: "—"
      }
  end

  defp both_disparity_scores_present?(%{score_cache: %{mob_score: m, critics_score: c}})
       when is_number(m) and is_number(c) and m > 0.0 and c > 0.0,
       do: true

  defp both_disparity_scores_present?(_), do: false

  defp six_degrees_teaser(date) do
    detail =
      a_lister_collaboration_query()
      |> Repo.replica().all()
      |> pick(date, :six_degrees)

    shape_six_degrees(detail)
  rescue
    exception ->
      log_homepage_error(:six_degrees_teaser, exception, __STACKTRACE__)
      empty_six_degrees()
  end

  @doc """
  Picks a fresh six-degrees pair at random — used by the LiveView shuffle button.
  Bypasses the daily cache; returns the same shape as the daily teaser.
  """
  def six_degrees_teaser_random do
    detail =
      a_lister_collaboration_query()
      |> Repo.replica().all()
      |> case do
        [] -> nil
        list -> Enum.random(list)
      end

    shape_six_degrees(detail)
  rescue
    exception ->
      log_homepage_error(:six_degrees_teaser_random, exception, __STACKTRACE__)
      empty_six_degrees()
  end

  defp a_lister_collaboration_query do
    from(d in CollaborationDetail,
      join: c in assoc(d, :collaboration),
      join: pa in assoc(c, :person_a),
      join: pb in assoc(c, :person_b),
      join: m in assoc(d, :movie),
      where: pa.adult == false and pb.adult == false,
      where: pa.popularity > 5.0 and pb.popularity > 5.0,
      where: m.adult == false and m.import_status == "full",
      order_by: [desc: c.collaboration_count, asc: d.id],
      preload: [movie: m, collaboration: {c, person_a: pa, person_b: pb}],
      limit: 100
    )
  end

  defp shape_six_degrees(nil), do: empty_six_degrees()

  defp shape_six_degrees(detail) do
    collab = detail.collaboration

    %{
      href: "/six-degrees",
      person_a: person_card(collab.person_a),
      person_b: person_card(collab.person_b),
      movie: film_card(detail.movie, compact: true),
      degrees: 1,
      summary:
        "#{collab.person_a.name} connects to #{collab.person_b.name} through #{detail.movie.title}."
    }
  end

  defp empty_six_degrees do
    %{
      href: "/six-degrees",
      person_a: nil,
      person_b: nil,
      movie: nil,
      degrees: nil,
      summary: "Try your own path through Cinegraph's collaboration graph."
    }
  end

  defp theater_movies(date) do
    movies = Movies.recent_theatrical_releases(today: date, days: 60, limit: 8)

    if length(movies) >= 4 do
      Enum.map(movies, &film_card(&1))
    else
      []
    end
  rescue
    exception ->
      log_homepage_error(:theater_movies, exception, __STACKTRACE__)
      []
  end

  defp festival_pulse(date) do
    %{
      next: next_festival(date),
      last: last_festival(date)
    }
  end

  defp next_festival(date) do
    result =
      from(d in FestivalDate,
        join: e in assoc(d, :festival_event),
        where: e.active == true,
        where: not is_nil(d.start_date) and d.start_date >= ^date,
        order_by: [asc: d.start_date],
        preload: [festival_event: e],
        limit: 1
      )
      |> Repo.replica().one()

    result && festival_card(result, date, :next)
  end

  defp last_festival(date) do
    result =
      from(d in FestivalDate,
        join: e in assoc(d, :festival_event),
        where: e.active == true,
        where: not is_nil(d.end_date) and d.end_date < ^date,
        order_by: [desc: d.end_date],
        preload: [festival_event: e],
        limit: 1
      )
      |> Repo.replica().one()

    result && festival_card(result, date, :last)
  end

  defp popular_lists do
    lists = MovieLists.all_displayable() |> Enum.take(10)
    source_keys = Enum.map(lists, & &1.source_key)
    counts_by_source_key = Movies.count_movies_by_list_keys(source_keys)
    shelves_by_source_key = Movies.list_canonical_shelf_movies_by_list_keys(source_keys, 5)

    Enum.map(lists, fn list ->
      films =
        shelves_by_source_key
        |> Map.get(list.source_key, [])
        |> Enum.map(&film_card(&1))

      %{
        id: list.id,
        title: list.short_name || list.name,
        name: list.name,
        description: list.description,
        href: "/lists/#{list.slug || list.source_key}",
        image_url: list.cover_image_url || list.hero_image_url,
        icon: list.icon,
        category: list.category,
        count: Map.get(counts_by_source_key, list.source_key, 0),
        films: films
      }
    end)
  rescue
    exception ->
      log_homepage_error(:popular_lists, exception, __STACKTRACE__)
      []
  end

  defp recent_ceremonies(_date) do
    Cinegraph.Festivals.list_recent_ceremonies_with_winner(6)
    |> Enum.map(fn entry ->
      org = entry.ceremony.organization
      slug = org && (org.slug || org.abbreviation)

      %{
        id: entry.ceremony.id,
        title: org && (org.name || org.abbreviation),
        year: entry.ceremony.year,
        href: slug && "/awards/#{slug}/winners",
        image_url: org && (org.hero_image_url || org.logo_url),
        winner_title: winner_title_for(entry),
        nomination_count: entry.nomination_count
      }
    end)
    |> Enum.reject(&is_nil(&1.href))
  rescue
    exception ->
      log_homepage_error(:recent_ceremonies, exception, __STACKTRACE__)
      []
  end

  defp winner_title_for(%{winner_movie: nil}), do: nil

  defp winner_title_for(%{winner_movie: movie, winner_category: cat}) when not is_nil(cat),
    do: "#{cat}: #{movie.title}"

  defp winner_title_for(%{winner_movie: movie}), do: "Winner: #{movie.title}"

  @clerk_demo_seeds [
    %{key: "heat", label: "If you liked Heat", tmdb_id: 949},
    %{key: "past_lives", label: "If you liked Past Lives", tmdb_id: 666_277},
    %{key: "mulholland", label: "If you liked Mulholland Drive", tmdb_id: 1018}
  ]

  @doc "Returns the static list of starter seeds offered in the home Video Clerk demo."
  def clerk_demo_seeds, do: @clerk_demo_seeds

  @doc """
  Looks up the seed by `key`, resolves it to an internal Movie id, calls the
  Video Clerk recommender, and returns a card-shaped result for `n_recommendation_card`.
  Cached daily per starter to avoid recomputing the same recommendation on every page load.
  """
  def clerk_demo(seed_key) when is_binary(seed_key) do
    seed = Enum.find(@clerk_demo_seeds, &(&1.key == seed_key)) || List.first(@clerk_demo_seeds)
    daily(:clerk_demo, {Date.utc_today(), seed_key}, fn -> compute_clerk_demo(seed) end)
  end

  defp compute_clerk_demo(seed) do
    case Repo.replica().get_by(Movie, tmdb_id: seed.tmdb_id) do
      nil ->
        empty_clerk_demo(seed)

      seed_movie ->
        case Cinegraph.VideoClerk.recommend([seed_movie.id], limit: 1) do
          %{primary: nil} ->
            empty_clerk_demo(seed)

          %{primary: primary} ->
            %{
              seed_label: seed.label,
              seed_movie: %{
                id: seed_movie.id,
                title: seed_movie.title,
                year: date_year(seed_movie.release_date)
              },
              recommendation: shape_clerk_recommendation(primary)
            }
        end
    end
  rescue
    exception ->
      log_homepage_error(:compute_clerk_demo, exception, __STACKTRACE__)
      empty_clerk_demo(seed)
  end

  defp shape_clerk_recommendation(primary) do
    %{
      id: primary.id,
      title: primary.title,
      year: primary.year,
      href: primary.href,
      poster_url: primary.poster_url,
      reason: Map.get(primary, :reason) || "The Video Clerk picked this for you.",
      evidence: primary |> Map.get(:route_labels, []) |> Enum.take(4)
    }
  end

  defp empty_clerk_demo(seed) do
    %{
      seed_label: seed.label,
      seed_movie: nil,
      recommendation: nil
    }
  end

  defp activity_rows do
    Activity.recent(7)
    |> Enum.flat_map(fn day ->
      [
        activity_row(:data, day.movies_added, "Added #{day.movies_added} films", day.date),
        activity_row(:data, day.people_added, "Added #{day.people_added} people", day.date),
        activity_row(
          :awards,
          day.ceremonies_updated,
          "Updated #{day.ceremonies_updated} ceremonies",
          day.date
        ),
        activity_row(
          :data,
          day.omdb_fetches,
          "Fetched #{day.omdb_fetches} OMDb records",
          day.date
        )
      ]
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(8)
    |> case do
      [] ->
        [
          %{
            type: :data,
            text: "Cinegraph activity will appear here as imports run.",
            ago: "today"
          }
        ]

      rows ->
        rows
    end
  rescue
    exception ->
      log_homepage_error(:activity_rows, exception, __STACKTRACE__)

      [%{type: :data, text: "Cinegraph activity will appear here as imports run.", ago: "today"}]
  end

  defp activity_row(_type, count, _text, _date) when count in [nil, 0], do: nil

  defp activity_row(type, _count, text, date) do
    %{type: type, text: text, ago: ago(date)}
  end

  defp film_card(movie, opts \\ []) do
    cache = loaded_cache(movie)
    score_field = Keyword.get(opts, :score_field, :overall_score)
    score = score_from(cache, score_field)

    %{
      id: movie.id,
      title: movie.title,
      year: date_year(movie.release_date),
      href: movie_href(movie),
      poster_url: Movie.poster_url(movie, "w342"),
      score: score,
      lens_key: Keyword.get(opts, :lens_key),
      score_tooltip: "Cinegraph score",
      reason: Keyword.get(opts, :reason),
      compact: Keyword.get(opts, :compact, false)
    }
  end

  defp person_card(person) do
    %{
      id: person.id,
      name: person.name,
      href: "/people/#{person.slug || person.id}",
      image_url: Person.profile_url(person, "w185"),
      role: person.known_for_department || "Film",
      known_for: [],
      delta_pct: 0,
      films: 0,
      trending: false
    }
  end

  defp festival_card(%FestivalDate{} = date_row, today, type) do
    event = date_row.festival_event
    start_date = date_row.start_date
    end_date = date_row.end_date || date_row.start_date

    %{
      title: "#{event.name} #{date_row.year}",
      href: "/awards/#{event.source_key}",
      eyebrow: if(type == :next, do: "Next festival", else: "Recent ceremony"),
      description:
        case type do
          :next ->
            days = Date.diff(start_date, today)

            cond do
              days <= 0 -> "Happening now"
              days == 1 -> "Starts #{Calendar.strftime(start_date, "%b %-d")} · tomorrow"
              true -> "Starts #{Calendar.strftime(start_date, "%b %-d")} · in #{days} days"
            end

          :last ->
            days_ago = Date.diff(today, end_date)

            cond do
              days_ago <= 1 ->
                "Finished #{Calendar.strftime(end_date, "%b %-d")} · yesterday"

              days_ago < 30 ->
                "Finished #{Calendar.strftime(end_date, "%b %-d")} · #{days_ago} days ago"

              true ->
                "Finished #{Calendar.strftime(end_date, "%b %-d %Y")}"
            end
        end,
      meta: compact([event.country, event.ceremony_vs_festival])
    }
  end

  defp active_list_count do
    from(ml in MovieList, where: ml.active == true, select: count(ml.id))
    |> Repo.replica().one()
    |> Kernel.||(0)
  end

  defp cached(key, ttl, fun) do
    case Cachex.fetch(@cache_name, key, fn -> {:commit, fun.(), ttl: ttl} end) do
      {:ok, value} -> value
      {:commit, value} -> value
      _ -> fun.()
    end
  rescue
    exception ->
      log_homepage_error(:cached, exception, __STACKTRACE__)
      fun.()
  end

  defp log_homepage_error(source, exception, stacktrace) do
    Logger.error(fn ->
      [
        "Homepage ",
        to_string(source),
        " failed\n",
        Exception.format(:error, exception, stacktrace)
      ]
    end)
  end

  defp daily(name, date, fun), do: cached({__MODULE__, name, date}, @daily_ttl, fun)

  defp hourly(name, date, fun),
    do: cached({__MODULE__, name, date, DateTime.utc_now().hour}, @hourly_ttl, fun)

  defp pick([], _date, _key), do: nil
  defp pick(list, date, key), do: Enum.at(list, :erlang.phash2({date, key}, length(list)))

  defp rotate([], _date, _key), do: []

  defp rotate(list, date, key) do
    {left, right} = Enum.split(list, :erlang.phash2({date, key}, length(list)))
    right ++ left
  end

  defp add_if_present(list, nil), do: list
  defp add_if_present(list, item), do: [item | list]

  defp movie_href(movie), do: "/movies/#{movie.slug || movie.id}"
  defp canonical_count(%{canonical_sources: sources}) when is_map(sources), do: map_size(sources)
  defp canonical_count(_), do: 0

  defp loaded_cache(%{score_cache: %MovieScoreCache{} = cache}), do: cache
  defp loaded_cache(_), do: nil

  defp score_from(nil, _field), do: nil
  defp score_from(cache, field), do: Map.get(cache, field)

  defp score_label(%MovieScoreCache{} = cache), do: score_label(%{score: cache.overall_score})

  defp score_label(%{score: score}) when is_number(score),
    do: "CRI #{:erlang.float_to_binary(score * 1.0, decimals: 1)}"

  defp score_label(_), do: nil

  defp disparity_stat(nil), do: "—"

  defp disparity_stat(cache) do
    "critics #{format_score_label(cache.critics_score)} · audience #{format_score_label(cache.mob_score)}"
  end

  defp format_score_label(nil), do: "—"
  defp format_score_label(score) when is_number(score) and score <= 0.0, do: "n/a"

  defp format_score_label(score) when is_number(score),
    do: :erlang.float_to_binary(score * 1.0, decimals: 1)

  defp format_score_label(_), do: "—"

  defp festival_status_copy(date_row, today) do
    start_date = date_row.start_date
    day = if start_date, do: Date.diff(today, start_date) + 1, else: nil
    if day && day > 0, do: "Day #{day} of the #{date_row.year} edition.", else: "Happening today."
  end

  defp date_year(nil), do: nil
  defp date_year(%Date{year: year}), do: year

  defp compact(list), do: Enum.reject(list, &(&1 in [nil, ""]))

  defp ago(date) do
    case Date.diff(Date.utc_today(), date) do
      0 -> "today"
      1 -> "1d"
      days -> "#{days}d"
    end
  end

  defp format_count(value) when is_integer(value) and value >= 1000 do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_count(value), do: to_string(value || 0)
end
