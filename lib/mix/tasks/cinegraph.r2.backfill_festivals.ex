defmodule Mix.Tasks.Cinegraph.R2.BackfillFestivals do
  @moduledoc """
  One-shot backfill (#890) — pushes existing festival imagery to Cloudflare R2.

  Walks every `festival_organizations` row. For each non-empty `logo_url` /
  `hero_image_url` that isn't already on our `R2_CDN_URL` host, downloads the
  image, uploads it to R2 at `festivals/{slug}/{logo|hero}-{hash8}.{ext}`, and
  rewrites the column to the resulting CDN URL.

  **Idempotent**: rows whose image URLs already start with the configured
  `R2_CDN_URL` are skipped. Safe to re-run.

  **Requires**: `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_ACCESS_KEY_ID`,
  `CLOUDFLARE_SECRET_ACCESS_KEY`, `R2_BUCKET`, `R2_CDN_URL` in env (see
  `.env`). Aborts with a clear message if R2 is not configured.

  ## Usage

      mix cinegraph.r2.backfill_festivals
      mix cinegraph.r2.backfill_festivals --dry-run   # report only, no writes
  """

  use Mix.Task

  alias Cinegraph.Festivals
  alias Cinegraph.Festivals.FestivalOrganization
  alias Cinegraph.Images.R2

  @shortdoc "Migrate festival logo + hero URLs onto Cloudflare R2 (#890)"
  @requirements ["app.start"]

  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, switches: [dry_run: :boolean])
    dry_run? = Keyword.get(opts, :dry_run, false)

    unless R2.configured?() do
      Mix.shell().error("""
      R2 is not configured. Set the following in .env:
        - CLOUDFLARE_ACCOUNT_ID
        - CLOUDFLARE_ACCESS_KEY_ID
        - CLOUDFLARE_SECRET_ACCESS_KEY
        - R2_CDN_URL
      """)

      System.halt(1)
    end

    cdn_base = Application.get_env(:cinegraph, :r2)[:cdn_url] |> String.trim_trailing("/")
    Mix.shell().info("R2 CDN base: #{cdn_base}#{if dry_run?, do: " (dry-run)"}")

    orgs = Festivals.list_organizations()
    Mix.shell().info("Scanning #{length(orgs)} festival organizations...")

    results =
      Enum.map(orgs, fn org ->
        %{
          org: org,
          logo: process_field(org, :logo_url, "logo", cdn_base, dry_run?),
          hero: process_field(org, :hero_image_url, "hero", cdn_base, dry_run?)
        }
      end)

    summarize(results)
  end

  defp process_field(org, attr, kind, cdn_base, dry_run?) do
    url = Map.get(org, attr)

    cond do
      url in [nil, ""] ->
        :empty

      String.starts_with?(url, cdn_base) ->
        :already_on_r2

      dry_run? ->
        {:would_rehost, url}

      true ->
        case rehost(org, attr, kind, url) do
          {:ok, cdn_url} -> {:rehosted, cdn_url}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp rehost(org, attr, kind, url) do
    with {:ok, cdn_url} <- R2.put_curated_image("festivals", org.slug, kind, {:url, url}),
         {:ok, _updated} <- update_org_field(org, attr, cdn_url) do
      {:ok, cdn_url}
    end
  end

  defp update_org_field(org, attr, cdn_url) do
    Festivals.update_organization(org, %{attr => cdn_url})
  end

  defp summarize(results) do
    slots =
      Enum.flat_map(results, fn %{logo: logo, hero: hero} -> [logo, hero] end)

    counts =
      slots
      |> Enum.frequencies_by(&tag/1)
      |> Map.merge(%{empty: 0, already_on_r2: 0, rehosted: 0, would_rehost: 0, error: 0}, fn
        _k, v1, _v2 -> v1
      end)

    Mix.shell().info("""

    ===== Backfill summary =====
    Festivals scanned:  #{length(results)}
    Logo+hero slots:    #{length(slots)}
      empty:            #{counts.empty}
      already on R2:    #{counts.already_on_r2}
      rehosted:         #{counts.rehosted}
      would rehost:     #{counts.would_rehost}
      errors:           #{counts.error}
    """)

    if counts.error > 0 do
      Mix.shell().error("Errors:")

      Enum.each(results, fn %{org: org, logo: logo, hero: hero} ->
        for {field, result} <- [{"logo", logo}, {"hero", hero}], match?({:error, _}, result) do
          {:error, reason} = result
          Mix.shell().error("  #{org.slug} (#{field}): #{inspect(reason)}")
        end
      end)
    end
  end

  defp tag(:empty), do: :empty
  defp tag(:already_on_r2), do: :already_on_r2
  defp tag({:rehosted, _}), do: :rehosted
  defp tag({:would_rehost, _}), do: :would_rehost
  defp tag({:error, _}), do: :error

  # Suppress unused-alias warning — kept for type-doc clarity.
  _ = FestivalOrganization
end
