defmodule CinegraphWeb.MovieLive.ShowV2.ProductionDetails do
  @moduledoc """
  Production-company details for the V2 movie show page.
  """

  use CinegraphWeb, :html

  alias Cinegraph.Movies.ProductionCompany

  @hero_company_limit 3

  attr :production_companies, :list, required: true

  def hero_production_companies(assigns) do
    assigns =
      assigns
      |> assign(:visible_companies, Enum.take(assigns.production_companies, @hero_company_limit))
      |> assign(
        :overflow_count,
        max(length(assigns.production_companies) - @hero_company_limit, 0)
      )

    ~H"""
    <div :if={@production_companies != []} class="flex items-center gap-2.5 flex-wrap">
      <span class="text-[10px] font-semibold text-white/55 tracking-[.06em] uppercase shrink-0">
        Studios
      </span>
      <div class="flex items-center gap-1.5 flex-wrap min-w-0">
        <.link
          :for={company <- @visible_companies}
          navigate={~p"/companies/#{production_company_slug_or_id(company)}"}
          title={production_company_name(company)}
          class="inline-flex items-center min-h-[28px] max-w-[180px] rounded-full bg-white/10 border border-white/15 px-2.5 py-1 text-[12px] font-medium text-white/85 no-underline hover:bg-white/15 hover:text-white backdrop-blur-sm"
        >
          <img
            :if={hero_company_logo_url(company)}
            src={hero_company_logo_url(company)}
            alt={production_company_name(company)}
            class="max-h-4 max-w-[88px] object-contain brightness-0 invert opacity-90"
            loading="lazy"
          />
          <span :if={!hero_company_logo_url(company)} class="truncate">
            {production_company_name(company)}
          </span>
        </.link>
        <span
          :if={@overflow_count > 0}
          class="inline-flex items-center min-h-[28px] rounded-full bg-white/5 border border-white/10 px-2.5 py-1 text-[12px] font-semibold text-white/65"
        >
          +{@overflow_count}
        </span>
      </div>
    </div>
    """
  end

  def production_details(assigns) do
    ~H"""
    <dd class="text-mist-950 text-right">
      <.link
        :for={{company, index} <- @production_companies |> Enum.take(2) |> Enum.with_index()}
        navigate={~p"/companies/#{production_company_slug_or_id(company)}"}
        class="underline decoration-mist-950/15 underline-offset-4 hover:text-mist-700"
      >
        <span :if={index > 0} class="text-mist-500 no-underline"> · </span>{production_company_name(
          company
        )}
      </.link>
    </dd>
    """
  end

  defp production_company_name(%{name: name}) when is_binary(name) do
    name_or_fallback(name)
  end

  defp production_company_name(%{production_company: %{name: name}}) when is_binary(name) do
    name_or_fallback(name)
  end

  defp production_company_name(_company), do: "—"

  defp hero_company_logo_url(company) do
    case company do
      %{logo_path: path} when is_binary(path) and path != "" ->
        ProductionCompany.logo_url(path, "w92")

      %{logo_url: url} when is_binary(url) and url != "" ->
        url

      %{production_company: nested} ->
        hero_company_logo_url(nested)

      _ ->
        nil
    end
  end

  defp name_or_fallback(name) do
    case String.trim(name) do
      "" -> "—"
      trimmed -> trimmed
    end
  end

  defp production_company_slug_or_id(%{slug: slug, id: id}) when is_binary(slug) do
    case String.trim(slug) do
      "" -> id
      trimmed -> trimmed
    end
  end

  defp production_company_slug_or_id(%{id: id}), do: id

  defp production_company_slug_or_id(%{production_company: company}),
    do: production_company_slug_or_id(company)
end
