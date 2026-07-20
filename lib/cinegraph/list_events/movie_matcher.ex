defmodule Cinegraph.ListEvents.MovieMatcher do
  @moduledoc """
  Resolves a scraped list entry to a `Cinegraph.Movies.Movie` (#1115).

  No title+year matcher existed before this — `Movies` only exposes lookup by
  exact `imdb_id`/`tmdb_id`. Resolution order:

    1. `raw_imdb_id` (when present) → `Movies.get_movie_by_imdb_id/1`
       (LIMIT-1, dup-safe per #1013).
    2. Normalized title + release-year within ±1 (editions and TMDb disagree on
       release year often enough that an exact-year match drops real films).

  Title normalization (applied to both the scrape title and `movies.title` /
  `original_title`): downcase, drop punctuation, collapse whitespace, then strip a
  single leading article. The Elixir side additionally folds accents; the SQL side
  cannot (this DB has no `unaccent` extension), so an accented stored title simply
  fails to match and the entry becomes `pending` — the safe, measured outcome
  (never a false positive).

  `match/1` returns `{:ok, %Movie{}, method}`, `:no_match`, or `:ambiguous` (more
  than one candidate). Ambiguity is never resolved by guessing — the caller routes
  it to a `pending` event so the count is measured, not hidden.
  """

  import Ecto.Query

  alias Cinegraph.Movies
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Repo

  @type entry :: %{
          optional(:raw_imdb_id) => String.t() | nil,
          optional(:raw_title) => String.t() | nil,
          optional(:raw_year) => integer() | nil
        }

  @type result :: {:ok, Movie.t(), atom()} | :no_match | :ambiguous

  # Kept identical to the SQL alternation in @article_strip_re below.
  @leading_articles ~w(the a an le la les l du de des el los las un une il lo gli)

  # SQL regexp that strips a single leading article token. Must stay in sync with
  # @leading_articles. Applied after punctuation/whitespace normalization so the
  # article is always a clean token followed by a space.
  @article_strip_re "^(the|a|an|le|la|les|l|du|de|des|el|los|las|un|une|il|lo|gli) "

  @doc """
  Resolve a scraped entry to a movie.

  Returns `{:ok, movie, method}` where `method` is `:imdb_id` or `:title_year`,
  `:no_match`, or `:ambiguous`.
  """
  @spec match(entry()) :: result()
  def match(entry) do
    with :no_match <- by_imdb(Map.get(entry, :raw_imdb_id)) do
      by_title_year(Map.get(entry, :raw_title), Map.get(entry, :raw_year))
    end
  end

  defp by_imdb(nil), do: :no_match
  defp by_imdb(""), do: :no_match

  defp by_imdb(imdb_id) when is_binary(imdb_id) do
    case Movies.get_movie_by_imdb_id(imdb_id) do
      %Movie{} = movie -> {:ok, movie, :imdb_id}
      nil -> :no_match
    end
  end

  defp by_title_year(nil, _year), do: :no_match
  defp by_title_year("", _year), do: :no_match

  defp by_title_year(title, year) do
    case normalize(title) do
      "" ->
        :no_match

      norm ->
        norm
        |> candidate_query(year)
        |> Repo.replica().all()
        |> case do
          [] -> :no_match
          [movie] -> {:ok, movie, :title_year}
          _multiple -> :ambiguous
        end
    end
  end

  # The SQL expression replicates `normalize/1` (minus accent folding): lower →
  # punctuation-to-space → whitespace-collapse → trim → strip leading article.
  defp candidate_query(norm, year) do
    base =
      from m in Movie,
        where:
          fragment(
            "btrim(regexp_replace(regexp_replace(regexp_replace(lower(?), '[^a-z0-9 ]', ' ', 'g'), '\\s+', ' ', 'g'), ?, '')) = ?",
            m.title,
            ^@article_strip_re,
            ^norm
          ) or
            fragment(
              "btrim(regexp_replace(regexp_replace(regexp_replace(lower(coalesce(?, '')), '[^a-z0-9 ]', ' ', 'g'), '\\s+', ' ', 'g'), ?, '')) = ?",
              m.original_title,
              ^@article_strip_re,
              ^norm
            ),
        order_by: m.id,
        limit: 2,
        select: m

    apply_year_window(base, year)
  end

  defp apply_year_window(query, nil), do: query

  defp apply_year_window(query, year) when is_integer(year) do
    from m in query,
      where:
        not is_nil(m.release_date) and
          fragment("date_part('year', ?)", m.release_date) >= ^(year - 1) and
          fragment("date_part('year', ?)", m.release_date) <= ^(year + 1)
  end

  @doc """
  Normalize a title for matching: downcase, fold accents, drop punctuation,
  collapse whitespace, strip a single leading article. Public so tests can assert
  on it and the SQL-side rules can be kept in sync.
  """
  @spec normalize(String.t() | nil) :: String.t()
  def normalize(nil), do: ""

  def normalize(title) when is_binary(title) do
    title
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9 ]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> strip_leading_article()
  end

  defp strip_leading_article(title) do
    case String.split(title, " ", parts: 2) do
      [first, rest] when first in @leading_articles -> rest
      _ -> title
    end
  end
end
