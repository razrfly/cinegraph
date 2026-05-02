defmodule Cinegraph.VideoClerk do
  @moduledoc """
  Explainable, non-collaborative movie recommendations for the Video Clerk.
  """

  import Ecto.Query

  alias Cinegraph.Movies.{Credit, Movie, MovieScoreCache, Person}
  alias Cinegraph.Repo

  @default_limit 4
  @candidate_limit 300

  @doc """
  Recommend one primary movie and alternates from one to three seed movie ids.
  """
  def recommend(seed_ids, opts \\ []) when is_list(seed_ids) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> max(1)

    seed_ids =
      seed_ids
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()
      |> Enum.take(3)

    seeds = load_seed_movies(seed_ids)

    if seeds == [] do
      empty_result([])
    else
      fingerprint = fingerprint(seeds)

      candidates = candidate_movies(seeds, fingerprint)
      person_overlap_by_movie = candidate_person_overlap_map(candidates, fingerprint.person_ids)

      scored =
        candidates
        |> Enum.reject(&(&1.id in seed_ids))
        |> Enum.map(&score_candidate(&1, fingerprint, person_overlap_by_movie))
        |> Enum.reject(&(&1.score <= 0))
        |> Enum.sort_by(&{&1.score, release_year_sort(&1.movie)}, :desc)
        |> Enum.take(limit)
        |> Enum.map(&shape_result/1)

      %{
        primary: List.first(scored),
        alternates: Enum.drop(scored, 1),
        seed_movies: seeds,
        route_labels: route_labels(scored),
        evidence_summary: evidence_summary(scored)
      }
    end
  end

  defp empty_result(seeds) do
    %{primary: nil, alternates: [], seed_movies: seeds, route_labels: [], evidence_summary: []}
  end

  defp load_seed_movies([]), do: []

  defp load_seed_movies(seed_ids) do
    Movie
    |> where([m], m.id in ^seed_ids)
    |> where([m], m.import_status == "full")
    |> preload([:genres, :keywords, :score_cache])
    |> Repo.replica().all()
    |> Enum.sort_by(fn movie -> Enum.find_index(seed_ids, &(&1 == movie.id)) || 999 end)
  end

  defp candidate_movies(seeds, fingerprint) do
    seed_ids = Enum.map(seeds, & &1.id)

    canonical =
      Movie
      |> where([m], m.import_status == "full")
      |> where([m], is_nil(m.release_date) or m.release_date <= ^Date.utc_today())
      |> where(
        [m],
        fragment("? \\? ?", m.canonical_sources, "cult_movies_400") or
          fragment("? \\? ?", m.canonical_sources, "1001_movies")
      )
      |> where([m], m.id not in ^seed_ids)
      |> order_by([m],
        desc: fragment("? \\? ?", m.canonical_sources, "cult_movies_400"),
        desc: fragment("? \\? ?", m.canonical_sources, "1001_movies"),
        desc_nulls_last: m.release_date
      )
      |> limit(@candidate_limit)
      |> preload([:genres, :keywords, :score_cache])
      |> Repo.replica().all()

    graph =
      graph_candidate_query(seed_ids, fingerprint)
      |> preload([:genres, :keywords, :score_cache])
      |> Repo.replica().all()

    (canonical ++ graph)
    |> Enum.uniq_by(& &1.id)
  end

  defp graph_candidate_query(seed_ids, fingerprint) do
    genre_ids = MapSet.to_list(fingerprint.genre_ids)
    keyword_ids = MapSet.to_list(fingerprint.keyword_ids)
    person_ids = MapSet.to_list(fingerprint.person_ids)

    Movie
    |> where([m], m.import_status == "full")
    |> where([m], is_nil(m.release_date) or m.release_date <= ^Date.utc_today())
    |> where([m], m.id not in ^seed_ids)
    |> join(:left, [m], g in "movie_genres", on: g.movie_id == m.id)
    |> join(:left, [m, g], k in "movie_keywords", on: k.movie_id == m.id)
    |> join(:left, [m, g, k], c in Credit, on: c.movie_id == m.id)
    |> where(
      [m, g, k, c],
      g.genre_id in ^genre_ids or k.keyword_id in ^keyword_ids or c.person_id in ^person_ids
    )
    |> group_by([m], m.id)
    |> order_by([m, g, k, c],
      desc:
        fragment(
          "COUNT(DISTINCT ?) + COUNT(DISTINCT ?) + COUNT(DISTINCT ?)",
          g.genre_id,
          k.keyword_id,
          c.person_id
        ),
      desc_nulls_last: m.release_date
    )
    |> limit(@candidate_limit)
  end

  defp fingerprint(seeds) do
    seed_ids = Enum.map(seeds, & &1.id)

    credits =
      Credit
      |> where([c], c.movie_id in ^seed_ids)
      |> where([c], c.credit_type == "cast" or c.job in ["Director", "Writer", "Screenplay"])
      |> preload([:person])
      |> Repo.replica().all()

    %{
      genre_ids: seeds |> Enum.flat_map(& &1.genres) |> ids(),
      keyword_ids: seeds |> Enum.flat_map(& &1.keywords) |> ids(),
      person_ids: credits |> Enum.map(& &1.person_id) |> MapSet.new(),
      people_names: people_names(credits),
      canonical_sources: seeds |> Enum.flat_map(&Movie.canonical_source_keys/1) |> MapSet.new(),
      seed_years: seeds |> Enum.map(&release_year/1) |> Enum.reject(&is_nil/1),
      seed_count: length(seeds)
    }
  end

  defp score_candidate(movie, fingerprint, person_overlap_by_movie) do
    genre_overlap = overlap_count(movie.genres, fingerprint.genre_ids)
    keyword_overlap = overlap_count(movie.keywords, fingerprint.keyword_ids)
    person_overlap = Map.get(person_overlap_by_movie, movie.id, 0)
    cult? = Movie.is_canonical?(movie, "cult_movies_400")
    canon? = Movie.is_canonical?(movie, "1001_movies")
    score_cache = loaded_score_cache(movie)

    evidence =
      []
      |> maybe_add(cult?, "Cult afterlife", 22)
      |> maybe_add(canon?, "Cultural memory", 18)
      |> maybe_add(person_overlap > 0, "Human graph", min(person_overlap * 8, 24))
      |> maybe_add(genre_overlap > 0, "Tone bridge", min(genre_overlap * 6, 18))
      |> maybe_add(keyword_overlap > 0, "Taste tension", min(keyword_overlap * 4, 16))
      |> maybe_add(
        score_cache && (score_cache.unpredictability_score || 0) > 0,
        "Taste tension",
        6
      )
      |> maybe_add(score_cache && (score_cache.overall_score || 0) > 0, "Cinegraph confidence", 4)

    score = Enum.reduce(evidence, 0, fn {_label, points}, acc -> acc + points end)

    %{
      movie: movie,
      score: score,
      evidence: merge_evidence(evidence),
      overlaps: %{
        genres: genre_overlap,
        keywords: keyword_overlap,
        people: person_overlap,
        score_cache: score_cache
      }
    }
  end

  defp shape_result(scored) do
    movie = scored.movie

    %{
      id: movie.id,
      title: movie.title,
      year: release_year(movie),
      slug: to_string(movie.slug),
      poster_url: Movie.poster_url(movie, "w342"),
      href: movie_href(movie),
      score: scored.score,
      evidence: scored.evidence,
      route_labels: Enum.map(scored.evidence, & &1.label),
      reason: reason(scored)
    }
  end

  defp reason(%{movie: movie, evidence: evidence, overlaps: overlaps}) do
    routes =
      evidence
      |> Enum.map(& &1.label)
      |> Enum.take(3)
      |> readable_join()

    detail =
      cond do
        overlaps.people > 0 ->
          "It shares creative DNA with your picks, then bends toward #{routes}."

        overlaps.genres > 0 or overlaps.keywords > 0 ->
          "It rhymes with the mood of your picks without collapsing into more of the same."

        true ->
          "It comes from Cinegraph's cult and cultural-memory shelves."
      end

    "#{movie.title} is the clerk's move: #{detail}"
  end

  defp candidate_person_overlap_map(candidates, seed_person_ids) do
    movie_ids = Enum.map(candidates, & &1.id)
    person_ids = MapSet.to_list(seed_person_ids)

    if person_ids == [] or movie_ids == [] do
      %{}
    else
      Credit
      |> where([c], c.movie_id in ^movie_ids)
      |> where([c], c.person_id in ^person_ids)
      |> group_by([c], c.movie_id)
      |> select([c], {c.movie_id, count(c.person_id, :distinct)})
      |> Repo.replica().all()
      |> Map.new()
    end
  end

  defp route_labels(results) do
    results
    |> Enum.flat_map(& &1.route_labels)
    |> Enum.uniq()
    |> Enum.take(5)
  end

  defp evidence_summary(results) do
    results
    |> Enum.flat_map(& &1.evidence)
    |> Enum.group_by(& &1.label)
    |> Enum.map(fn {label, rows} ->
      %{label: label, points: Enum.sum(Enum.map(rows, & &1.points))}
    end)
    |> Enum.sort_by(& &1.points, :desc)
    |> Enum.take(5)
    |> Enum.map(& &1.label)
  end

  defp ids(rows), do: rows |> Enum.map(& &1.id) |> MapSet.new()

  defp people_names(credits) do
    credits
    |> Enum.map(fn
      %{person: %Person{name: name}} -> name
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp overlap_count(rows, ids) do
    rows
    |> Enum.map(& &1.id)
    |> MapSet.new()
    |> MapSet.intersection(ids)
    |> MapSet.size()
  end

  defp maybe_add(evidence, true, label, points), do: [{label, points} | evidence]
  defp maybe_add(evidence, _condition, _label, _points), do: evidence

  defp merge_evidence(evidence) do
    evidence
    |> Enum.group_by(fn {label, _points} -> label end, fn {_label, points} -> points end)
    |> Enum.map(fn {label, points} -> %{label: label, points: Enum.sum(points)} end)
    |> Enum.sort_by(& &1.points, :desc)
  end

  defp loaded_score_cache(%{score_cache: %MovieScoreCache{} = cache}), do: cache
  defp loaded_score_cache(_), do: nil

  defp release_year(%Movie{release_date: %Date{year: year}}), do: year
  defp release_year(_movie), do: nil
  defp release_year_sort(movie), do: release_year(movie) || 0

  defp movie_href(%Movie{slug: slug}) when not is_nil(slug), do: "/movies/#{slug}"
  defp movie_href(%Movie{imdb_id: imdb_id}) when is_binary(imdb_id), do: "/movies/imdb/#{imdb_id}"
  defp movie_href(_movie), do: "#"

  defp readable_join([]), do: "Cinegraph evidence"
  defp readable_join([one]), do: one
  defp readable_join([one, two]), do: "#{one} and #{two}"

  defp readable_join(labels) do
    {last, rest} = List.pop_at(labels, -1)
    "#{Enum.join(rest, ", ")}, and #{last}"
  end
end
