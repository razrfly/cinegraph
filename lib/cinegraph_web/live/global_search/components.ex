defmodule CinegraphWeb.GlobalSearch.Components do
  @moduledoc false

  use Phoenix.Component

  import CinegraphWeb.CoreComponents, only: [icon: 1]

  alias Cinegraph.Movies.{Movie, ProductionCompany}

  def render_recents(assigns) do
    ~H"""
    <ul class="py-2">
      <li class="px-4 pt-2 pb-1 text-[10.5px] uppercase tracking-[.08em] text-mist-500 dark:text-mist-400 font-semibold">
        Recent
      </li>
      <li :for={r <- @recents} class="px-2">
        <a
          href={recent_href(r)}
          role="option"
          class="flex items-center gap-2 px-2 py-2 rounded-md text-[13px] text-mist-950 dark:text-white hover:bg-mist-50 dark:hover:bg-white/5 no-underline"
        >
          <span class="text-mist-500 dark:text-mist-400" aria-hidden="true">🕘</span>
          {r["label"]}
        </a>
      </li>
    </ul>
    """
  end

  defp recent_href(%{"href" => href} = recent) do
    case safe_recent_href(href) do
      "#" -> recent_search_href(recent)
      href -> href
    end
  end

  defp recent_href(recent), do: recent_search_href(recent)

  defp recent_search_href(%{"label" => label}) when is_binary(label) do
    query = String.trim(label)

    if query == "" do
      "#"
    else
      "/movies?search=#{URI.encode_www_form(query)}"
    end
  end

  defp recent_search_href(_), do: "#"

  defp safe_recent_href(href) when is_binary(href) do
    uri = URI.parse(href)

    if String.starts_with?(href, "/") and not String.starts_with?(href, "//") and
         is_nil(uri.scheme) and is_nil(uri.host) do
      href
    else
      "#"
    end
  end

  defp safe_recent_href(_), do: "#"

  def render_skeleton(assigns) do
    ~H"""
    <div class="py-2">
      <div :for={_ <- 1..3} class="flex items-center gap-3 px-4 py-2">
        <div class="w-10 h-10 rounded-md bg-mist-100 dark:bg-white/5 animate-pulse" />
        <div class="flex-1 space-y-1">
          <div class="h-3 w-3/4 bg-mist-100 dark:bg-white/5 rounded animate-pulse" />
          <div class="h-2 w-1/2 bg-mist-100 dark:bg-white/5 rounded animate-pulse" />
        </div>
      </div>
    </div>
    """
  end

  def render_results(assigns) do
    ~H"""
    <div class="py-2 divide-y divide-mist-950/[0.06] dark:divide-white/[0.06]">
      <.section :if={@results.films != []} title="Films">
        <:row :for={f <- @results.films}>
          <.film_row film={f} />
        </:row>
      </.section>

      <.section :if={@results.people != []} title="People">
        <:row :for={p <- @results.people}>
          <.person_row person={p} />
        </:row>
      </.section>

      <.section :if={@results.lists != []} title="Lists">
        <:row :for={l <- @results.lists}>
          <.list_row list={l} />
        </:row>
      </.section>

      <.section :if={@results.companies != []} title="Companies">
        <:row :for={c <- @results.companies}>
          <.company_row company={c} />
        </:row>
      </.section>
    </div>
    """
  end

  attr :title, :string, required: true
  slot :row

  def section(assigns) do
    ~H"""
    <section class="py-1">
      <div class="px-4 pt-2 pb-1 text-[10.5px] uppercase tracking-[.08em] text-mist-500 dark:text-mist-400 font-semibold">
        {@title}
      </div>
      <ul class="px-2">
        <li :for={r <- @row} class="px-0">{render_slot(r)}</li>
      </ul>
    </section>
    """
  end

  attr :film, :map, required: true

  def film_row(assigns) do
    ~H"""
    <a
      href={"/movies/" <> @film.slug}
      role="option"
      class="flex items-center gap-3 px-2 py-2 rounded-md hover:bg-mist-50 dark:hover:bg-white/5 no-underline"
    >
      <div class="w-10 h-[60px] rounded bg-mist-100 dark:bg-white/5 overflow-hidden shrink-0 grid place-items-center">
        <img
          :if={@film.poster_path}
          src={Movie.image_url(@film.poster_path, "w92")}
          alt=""
          loading="lazy"
          decoding="async"
          class="w-full h-full object-cover"
        />
        <span
          :if={!@film.poster_path}
          class="text-mist-400 dark:text-mist-500 text-lg"
          aria-hidden="true"
        >
          🎬
        </span>
      </div>
      <div class="flex-1 min-w-0">
        <div class="text-[13.5px] text-mist-950 dark:text-white truncate">{@film.title}</div>
        <div class="text-[11.5px] text-mist-500 dark:text-mist-400 truncate">
          <span :if={@film.year}>{@film.year}</span>
          <span :if={@film.year && @film.director}> · </span>
          <span :if={@film.director}>dir. {@film.director}</span>
        </div>
      </div>
    </a>
    """
  end

  attr :person, :map, required: true

  def person_row(assigns) do
    ~H"""
    <a
      href={person_href(@person)}
      role="option"
      class="flex items-center gap-3 px-2 py-2 rounded-md hover:bg-mist-50 dark:hover:bg-white/5 no-underline"
    >
      <div class="w-10 h-10 rounded-full bg-mist-100 dark:bg-white/5 overflow-hidden shrink-0 grid place-items-center">
        <img
          :if={@person.profile_path}
          src={Movie.image_url(@person.profile_path, "w92")}
          alt=""
          loading="lazy"
          decoding="async"
          class="w-full h-full object-cover"
        />
        <span
          :if={!@person.profile_path}
          class="text-[10.5px] font-semibold text-mist-500 dark:text-mist-400 uppercase"
          aria-hidden="true"
        >
          {initials(@person.name)}
        </span>
      </div>
      <div class="flex-1 min-w-0">
        <div class="text-[13.5px] text-mist-950 dark:text-white truncate">{@person.name}</div>
        <div
          :if={@person.known_for_department}
          class="text-[11.5px] text-mist-500 dark:text-mist-400 truncate"
        >
          {@person.known_for_department}
        </div>
      </div>
    </a>
    """
  end

  defp person_href(%{slug: slug}) when is_binary(slug) and slug != "", do: "/people/#{slug}"
  defp person_href(%{id: id}), do: "/people/#{id}"

  attr :list, :map, required: true

  def list_row(assigns) do
    ~H"""
    <a
      href={"/lists/" <> @list.slug}
      role="option"
      class="flex items-center gap-3 px-2 py-2 rounded-md hover:bg-mist-50 dark:hover:bg-white/5 no-underline"
    >
      <div
        class="w-10 h-10 rounded bg-mist-100 dark:bg-white/5 grid place-items-center shrink-0"
        aria-hidden="true"
      >
        <%= if is_binary(@list.icon) && String.trim(@list.icon) != "" do %>
          <.icon name={"hero-" <> @list.icon} class="w-5 h-5 text-mist-500 dark:text-mist-400" />
        <% else %>
          <span class="text-lg">📜</span>
        <% end %>
      </div>
      <div class="flex-1 min-w-0">
        <div class="text-[13.5px] text-mist-950 dark:text-white truncate">{@list.name}</div>
        <div
          :if={@list.short_name && @list.short_name != @list.name}
          class="text-[11.5px] text-mist-500 dark:text-mist-400 truncate"
        >
          {@list.short_name}
        </div>
      </div>
    </a>
    """
  end

  attr :company, :map, required: true

  def company_row(assigns) do
    ~H"""
    <a
      href={company_href(@company)}
      role="option"
      class="flex items-center gap-3 px-2 py-2 rounded-md hover:bg-mist-50 dark:hover:bg-white/5 no-underline"
    >
      <div class="w-10 h-10 rounded bg-mist-100 dark:bg-white/5 overflow-hidden grid place-items-center shrink-0">
        <img
          :if={company_logo(@company)}
          src={company_logo(@company)}
          alt=""
          loading="lazy"
          decoding="async"
          class="max-w-full max-h-full object-contain"
        />
        <span
          :if={!company_logo(@company)}
          class="text-mist-400 dark:text-mist-500 text-lg"
          aria-hidden="true"
        >
          🏢
        </span>
      </div>
      <div class="flex-1 min-w-0">
        <div class="text-[13.5px] text-mist-950 dark:text-white truncate">{@company.name}</div>
        <div
          :if={@company.origin_country}
          class="text-[11.5px] text-mist-500 dark:text-mist-400 truncate"
        >
          {@company.origin_country}
        </div>
      </div>
    </a>
    """
  end

  defp company_href(%{slug: slug}) when is_binary(slug) and slug != "", do: "/companies/#{slug}"
  defp company_href(%{id: id}), do: "/companies/#{id}"

  defp company_logo(%{logo_url: url}) when is_binary(url) and url != "", do: url

  defp company_logo(%{logo_path: path}) when is_binary(path) and path != "",
    do: ProductionCompany.logo_url(path, "w92")

  defp company_logo(_company), do: nil

  defp initials(nil), do: "?"

  defp initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.first/1)
    |> String.upcase()
  end
end
