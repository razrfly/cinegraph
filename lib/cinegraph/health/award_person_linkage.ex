defmodule Cinegraph.Health.AwardPersonLinkage do
  @moduledoc """
  Audit person-award linkage drift per festival organization (#873).

  Classifies `festival_nominations` rows where the category tracks a person
  into buckets that explain why `person_id IS NULL`:

  - `resolved` — `person_id IS NOT NULL` (linked).
  - `missing_person_with_imdb_ids` — NULL person_id but details has non-empty
    `person_imdb_ids`; resolver can link by IMDb ID.
  - `missing_person_with_name` — NULL person_id, no imdb_ids, but has a
    `nominee_names` string; resolver can try credit/TMDb fallback.
  - `has_people_in_details` — NULL person_id with empty name/imdb_ids, but
    details has the raw `people` list preserved (Phase 0 fix was applied
    during import); resolver may be able to use that data.
  - `empty_person_payload` — NULL person_id, no usable name, imdb_ids, or
    people list; row needs a source reimport to recover.
  - `needs_reimport` — subset of empty_payload that also lacks `people` in
    details (i.e., imported before the Phase 0 fix).
  """

  import Ecto.Query
  alias Cinegraph.Repo

  @doc """
  Run the audit. Returns a JSON-encodable map.

  Options:
    * `:org` — festival organization abbreviation, e.g. `"HFPA"` (default: all).
    * `:limit` — max example rows returned (default: 5).
  """
  def audit(opts \\ []) do
    org_abbr = Keyword.get(opts, :org)
    limit = Keyword.get(opts, :limit, 5)

    counts = fetch_counts(org_abbr)
    examples = fetch_examples(org_abbr, limit)

    missing = counts.total - counts.resolved

    %{
      generated_at: DateTime.utc_now(),
      organization: org_abbr || "all",
      summary: %{
        person_required_total: counts.total,
        resolved: counts.resolved,
        missing_person_id: missing,
        recoverable_with_imdb_id: counts.with_imdb_ids,
        recoverable_with_name: counts.with_name_only,
        has_people_in_details: counts.with_people_in_details,
        empty_person_payload: counts.empty_payload,
        needs_reimport: max(0, counts.empty_payload - counts.with_people_in_details)
      },
      examples: examples
    }
  end

  # ===== private =====

  defp fetch_counts(org_abbr) do
    base = tracked_query(org_abbr)
    missing = from([n] in base, where: is_nil(n.person_id))

    total = Repo.replica().one(from([n] in base, select: count(n.id))) || 0

    resolved =
      Repo.replica().one(from([n] in base, where: not is_nil(n.person_id), select: count(n.id))) ||
        0

    with_imdb_ids =
      Repo.replica().one(
        from([n] in missing,
          where:
            fragment(
              "(? -> 'person_imdb_ids') IS NOT NULL AND (? -> 'person_imdb_ids') != '[]'::jsonb",
              n.details,
              n.details
            ),
          select: count(n.id)
        )
      ) || 0

    with_name_only =
      Repo.replica().one(
        from([n] in missing,
          where:
            fragment(
              "(? ->> 'nominee_names') IS NOT NULL AND (? ->> 'nominee_names') != '' AND (? -> 'person_imdb_ids' IS NULL OR ? -> 'person_imdb_ids' = '[]'::jsonb)",
              n.details,
              n.details,
              n.details,
              n.details
            ),
          select: count(n.id)
        )
      ) || 0

    with_people_in_details =
      Repo.replica().one(
        from([n] in missing,
          where:
            fragment(
              "(? -> 'people') IS NOT NULL AND jsonb_array_length(? -> 'people') > 0",
              n.details,
              n.details
            ),
          select: count(n.id)
        )
      ) || 0

    empty_payload =
      Repo.replica().one(
        from([n] in missing,
          where:
            fragment(
              "(? ->> 'nominee_names' IS NULL OR ? ->> 'nominee_names' = '') AND (? -> 'person_imdb_ids' IS NULL OR ? -> 'person_imdb_ids' = '[]'::jsonb)",
              n.details,
              n.details,
              n.details,
              n.details
            ),
          select: count(n.id)
        )
      ) || 0

    %{
      total: total,
      resolved: resolved,
      with_imdb_ids: with_imdb_ids,
      with_name_only: with_name_only,
      with_people_in_details: with_people_in_details,
      empty_payload: empty_payload
    }
  end

  defp fetch_examples(org_abbr, limit) do
    base = tracked_query(org_abbr)

    from([n, c] in base,
      where: is_nil(n.person_id),
      select: %{
        id: n.id,
        category: c.name,
        ceremony_id: n.ceremony_id,
        movie_id: n.movie_id,
        has_imdb_ids:
          fragment(
            "(? -> 'person_imdb_ids') IS NOT NULL AND (? -> 'person_imdb_ids') != '[]'::jsonb",
            n.details,
            n.details
          ),
        has_nominee_name:
          fragment(
            "(? ->> 'nominee_names') IS NOT NULL AND (? ->> 'nominee_names') != ''",
            n.details,
            n.details
          ),
        has_people_in_details:
          fragment(
            "(? -> 'people') IS NOT NULL AND jsonb_array_length(? -> 'people') > 0",
            n.details,
            n.details
          )
      },
      order_by: n.id,
      limit: ^limit
    )
    |> Repo.replica().all()
  end

  defp tracked_query(nil) do
    from(n in "festival_nominations",
      join: c in "festival_categories",
      on: n.category_id == c.id,
      where: c.tracks_person == true
    )
  end

  defp tracked_query(abbr) when is_binary(abbr) do
    from(n in "festival_nominations",
      join: c in "festival_categories",
      on: n.category_id == c.id,
      join: cer in "festival_ceremonies",
      on: n.ceremony_id == cer.id,
      join: org in "festival_organizations",
      on: cer.organization_id == org.id,
      where: c.tracks_person == true and org.abbreviation == ^abbr
    )
  end
end
