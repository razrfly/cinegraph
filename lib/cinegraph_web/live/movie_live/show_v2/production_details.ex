defmodule CinegraphWeb.MovieLive.ShowV2.ProductionDetails do
  @moduledoc """
  Production-company details for the V2 movie show page.
  """

  use CinegraphWeb, :html

  alias Cinegraph.Movies.ProductionCompany
  import CinegraphWeb.PersonHelpers, only: [person_slug_or_id: 1]

  @hero_company_limit 3
  @hero_cast_limit 5

  attr :directors, :list, required: true
  attr :cast, :list, required: true

  @doc "Renders compact director and starring metadata rows for the movie hero."
  def hero_people(assigns) do
    assigns =
      assigns
      |> assign(:top_cast, Enum.take(assigns.cast, @hero_cast_limit))
      |> assign(:cast_overflow_count, max(length(assigns.cast) - @hero_cast_limit, 0))

    ~H"""
    <div :if={@directors != [] || @top_cast != []} class="space-y-2.5">
      <.hero_people_row label="Directed by" credits={@directors} />
      <.hero_people_row label="Starring" credits={@top_cast} overflow_count={@cast_overflow_count} />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :credits, :list, required: true
  attr :overflow_count, :integer, default: 0

  defp hero_people_row(assigns) do
    ~H"""
    <div :if={@credits != []} class="flex items-center gap-2.5 flex-wrap">
      <span class="text-[10px] font-semibold text-white/55 tracking-[.06em] uppercase shrink-0">
        {@label}
      </span>
      <div class="flex -space-x-2 shrink-0">
        <a
          :for={credit <- @credits}
          href={person_href(credit.person)}
          title={credit.person.name}
          class="block no-underline"
        >
          <img
            :if={credit.person.profile_path}
            src={tmdb_url(credit.person.profile_path, "w185")}
            alt={credit.person.name}
            class="w-7 h-7 rounded-full border-2 border-mist-950 object-cover bg-mist-800"
          />
          <div
            :if={!credit.person.profile_path}
            class="w-7 h-7 rounded-full border-2 border-mist-950 bg-white/15 grid place-items-center text-[10px] text-white/70"
          >
            {person_initial(credit.person)}
          </div>
        </a>
      </div>
      <div class="text-[13.5px] text-white/85 min-w-0">
        <%= for {credit, idx} <- Enum.with_index(@credits) do %>
          {if idx > 0, do: ", "}<a
            href={person_href(credit.person)}
            class="text-white/85 hover:text-white no-underline"
          >{credit.person.name}</a>
        <% end %>
        <a
          :if={@overflow_count > 0}
          href="#cast"
          data-scroll-to="cast"
          class="ml-1 text-blue-300 hover:text-blue-200 no-underline"
        >
          +{@overflow_count} more
        </a>
      </div>
    </div>
    """
  end

  attr :production_companies, :list, required: true

  @doc "Renders the compact studio logo row for the movie hero."
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
        <.link
          :if={@overflow_count > 0}
          href="#studios"
          data-scroll-to="studios"
          class="inline-flex items-center min-h-[28px] rounded-full bg-white/5 border border-white/10 px-2.5 py-1 text-[12px] font-semibold text-white/65"
        >
          +{@overflow_count}
        </.link>
      </div>
    </div>
    """
  end

  attr :production_companies, :list, required: true

  @doc "Renders the full studio section for the movie detail page."
  def studios_section(assigns) do
    ~H"""
    <div :if={@production_companies != []}>
      <div class="flex items-end justify-between mb-6 flex-wrap gap-3">
        <h2 class="font-display italic text-[28px] sm:text-[32px] tracking-[-.01em] text-mist-950 dark:text-white">
          Studios
          <span class="text-mist-500 dark:text-mist-400 text-[14px] font-sans not-italic tabular-nums ml-2">
            {length(@production_companies)}
          </span>
        </h2>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
        <.link
          :for={company <- @production_companies}
          navigate={~p"/companies/#{production_company_slug_or_id(company)}"}
          class="group flex items-center gap-3 min-h-[56px] rounded-lg border border-mist-950/10 dark:border-white/10 bg-white dark:bg-mist-900 px-3 py-2 no-underline hover:border-mist-950/25 dark:hover:border-white/20 hover:bg-mist-50 dark:hover:bg-mist-800"
        >
          <div class="h-9 w-16 shrink-0 rounded-md border border-mist-950/10 dark:border-white/10 bg-mist-50 dark:bg-mist-800 grid place-items-center overflow-hidden">
            <img
              :if={hero_company_logo_url(company)}
              src={hero_company_logo_url(company)}
              alt={production_company_name(company)}
              class="max-h-6 max-w-14 object-contain"
              loading="lazy"
            />
            <span
              :if={!hero_company_logo_url(company)}
              class="text-[11px] font-semibold text-mist-500 dark:text-mist-400"
            >
              {company_initial(company)}
            </span>
          </div>
          <span class="min-w-0 text-[13px] font-semibold text-mist-950 dark:text-white group-hover:text-mist-700 dark:group-hover:text-mist-300 truncate">
            {production_company_name(company)}
          </span>
        </.link>
      </div>
    </div>
    """
  end

  @doc "Renders production-company links for the facts/details list."
  attr :production_companies, :list, required: true

  def production_details(assigns) do
    ~H"""
    <dd class="text-mist-950 dark:text-white text-right">
      <.link
        :for={{company, index} <- @production_companies |> Enum.take(2) |> Enum.with_index()}
        navigate={~p"/companies/#{production_company_slug_or_id(company)}"}
        class="underline decoration-mist-950/15 dark:decoration-white/15 underline-offset-4 hover:text-mist-700 dark:hover:text-mist-300"
      >
        <span :if={index > 0} class="text-mist-500 dark:text-mist-400 no-underline"> · </span>{production_company_name(
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

  defp person_href(person), do: "/people/#{person_slug_or_id(person)}"

  defp tmdb_url(nil, _), do: nil
  defp tmdb_url("", _), do: nil
  defp tmdb_url("/" <> _ = path, size), do: "https://image.tmdb.org/t/p/#{size}#{path}"
  defp tmdb_url(path, size), do: "https://image.tmdb.org/t/p/#{size}/#{path}"

  defp person_initial(%{name: name}) when is_binary(name), do: String.first(name)
  defp person_initial(_person), do: "?"

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

  defp company_initial(company) do
    company
    |> production_company_name()
    |> String.trim()
    |> String.first()
    |> case do
      nil -> "•"
      "" -> "•"
      initial -> initial
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
