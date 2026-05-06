defmodule CinegraphWeb.Admin.FestivalsLive.Index do
  @moduledoc """
  Festival admin index — replaces the bare `/admin/festival-events` modal
  with a real editor for `festival_organizations`.

  Phase 2 of #880. Lets a human:

  - See every festival org at a glance, with logo / hero image-coverage badges
  - Click into a drawer to edit identity + imagery
  - Paste a URL for `logo_url` / `hero_image_url`, OR open the "Suggest images"
    modal to search Unsplash / Pexels / Pixabay and click-to-save a CDN URL
  - Link out to `/admin/festival/:slug` for ceremony audit and to
    `/admin/festival-events` for import-config edits (until those fold in
    in a follow-up phase)
  """
  use CinegraphWeb, :admin_live_view

  alias Cinegraph.Festivals
  alias Cinegraph.Festivals.FestivalOrganization
  alias Cinegraph.Images.StockImageSearch

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Festivals")
     |> assign(:editing_org, nil)
     |> assign(:form, nil)
     |> assign(:suggest_for, nil)
     |> assign(:suggest_query, "")
     |> assign(:suggest_results, %{})
     |> assign(:suggest_loading?, false)
     |> assign(:suggest_search_ref, nil)
     |> assign_orgs()}
  end

  defp assign_orgs(socket) do
    orgs = Festivals.list_organizations()

    stats = %{
      total: length(orgs),
      with_logo: Enum.count(orgs, &has_url?(&1.logo_url)),
      with_hero: Enum.count(orgs, &has_url?(&1.hero_image_url))
    }

    socket
    |> assign(:orgs, orgs)
    |> assign(:stats, stats)
  end

  defp has_url?(nil), do: false
  defp has_url?(""), do: false
  defp has_url?(_), do: true

  @impl true
  def handle_event("edit_org", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.orgs, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Festival not found.")}

      org ->
        {:noreply, open_drawer(socket, org)}
    end
  end

  def handle_event("close_drawer", _params, socket) do
    {:noreply, close_drawer(socket)}
  end

  def handle_event("validate", %{"organization" => attrs}, socket) do
    case socket.assigns.editing_org do
      nil ->
        {:noreply, socket}

      org ->
        changeset =
          org
          |> FestivalOrganization.changeset(attrs)
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, :form, to_form(changeset, as: "organization"))}
    end
  end

  def handle_event("save", %{"organization" => attrs}, socket) do
    org = socket.assigns.editing_org

    case Festivals.update_organization(org, attrs) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign_orgs()
         |> close_drawer()
         |> put_flash(:info, "Saved #{updated.name}.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset, as: "organization"))
         |> put_flash(:error, "Could not save festival — see field errors.")}
    end
  end

  def handle_event("open_suggest", %{"field" => field}, socket)
      when field in ["logo_url", "hero_image_url"] do
    field_atom = String.to_existing_atom(field)
    query = socket.assigns.editing_org.name

    {:noreply,
     socket
     |> assign(:suggest_for, field_atom)
     |> assign(:suggest_query, query)
     |> start_suggest_search(query)}
  end

  def handle_event("close_suggest", _params, socket) do
    {:noreply,
     socket
     |> assign(:suggest_for, nil)
     |> assign(:suggest_query, "")
     |> assign(:suggest_results, %{})
     |> assign(:suggest_loading?, false)
     |> assign(:suggest_search_ref, nil)}
  end

  def handle_event("suggest_search", %{"q" => q}, socket) do
    query = String.trim(q)

    {:noreply,
     socket
     |> assign(:suggest_query, query)
     |> start_suggest_search(query)}
  end

  def handle_event("use_image", %{"url" => url}, socket) do
    field = socket.assigns.suggest_for

    case {field, socket.assigns.editing_org} do
      {nil, _} ->
        {:noreply, socket}

      {_, nil} ->
        {:noreply, socket}

      {field, org} ->
        # Patch the in-memory form changeset so the drawer's text input updates
        existing_params =
          case socket.assigns.form do
            %Phoenix.HTML.Form{params: p} when is_map(p) -> p
            _ -> %{}
          end

        new_params = Map.put(existing_params, to_string(field), url)

        changeset =
          org
          |> FestivalOrganization.changeset(new_params)
          |> Map.put(:action, :validate)

        {:noreply,
         socket
         |> assign(:form, to_form(changeset, as: "organization"))
         |> assign(:suggest_for, nil)
         |> assign(:suggest_results, %{})
         |> assign(:suggest_loading?, false)
         |> assign(:suggest_search_ref, nil)}
    end
  end

  @impl true
  def handle_info({:suggest_results, ref, query, results}, socket) do
    if socket.assigns.suggest_search_ref == ref and socket.assigns.suggest_query == query do
      {:noreply,
       socket
       |> assign(:suggest_results, results)
       |> assign(:suggest_loading?, false)}
    else
      {:noreply, socket}
    end
  end

  defp open_drawer(socket, org) do
    changeset = FestivalOrganization.changeset(org, %{})

    socket
    |> assign(:editing_org, org)
    |> assign(:form, to_form(changeset, as: "organization"))
  end

  defp close_drawer(socket) do
    socket
    |> assign(:editing_org, nil)
    |> assign(:form, nil)
    |> assign(:suggest_for, nil)
    |> assign(:suggest_query, "")
    |> assign(:suggest_results, %{})
    |> assign(:suggest_loading?, false)
    |> assign(:suggest_search_ref, nil)
  end

  defp start_suggest_search(socket, ""), do: clear_suggest_search(socket)

  defp start_suggest_search(socket, query) do
    ref = make_ref()

    if connected?(socket) do
      live_view = self()

      case Task.Supervisor.start_child(Cinegraph.Images.TaskSupervisor, fn ->
             send(live_view, {:suggest_results, ref, query, StockImageSearch.search(query, 6)})
           end) do
        {:ok, _pid} ->
          socket
          |> assign(:suggest_results, %{})
          |> assign(:suggest_loading?, true)
          |> assign(:suggest_search_ref, ref)

        _ ->
          clear_suggest_search(socket)
      end
    else
      socket
      |> assign(:suggest_results, StockImageSearch.search(query, 6))
      |> assign(:suggest_loading?, false)
      |> assign(:suggest_search_ref, nil)
    end
  end

  defp clear_suggest_search(socket) do
    socket
    |> assign(:suggest_results, %{})
    |> assign(:suggest_loading?, false)
    |> assign(:suggest_search_ref, nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title="Festivals"
      subtitle={
        "#{@stats.total} organizations · #{@stats.with_logo} with logo · #{@stats.with_hero} with hero image"
      }
    >
      <:actions>
        <.link
          navigate="/admin/festival"
          class="text-sm font-medium text-blue-700 hover:text-blue-900"
        >
          Ceremony audit →
        </.link>
      </:actions>
    </.page_header>

    <.section_card>
      <div class="overflow-x-auto">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">Logo</th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                Festival
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">Country</th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">Tier</th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">Hero</th>
              <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">Action</th>
            </tr>
          </thead>
          <tbody class="bg-white divide-y divide-gray-200">
            <%= for org <- @orgs do %>
              <tr class="hover:bg-gray-50">
                <td class="px-4 py-2">
                  <%= if has_url?(org.logo_url) do %>
                    <img
                      src={org.logo_url}
                      alt={"#{org.name} logo"}
                      class="h-10 w-10 object-contain bg-gray-50 rounded"
                    />
                  <% else %>
                    <span class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-amber-100 text-amber-800">
                      no logo
                    </span>
                  <% end %>
                </td>
                <td class="px-4 py-2 text-sm">
                  <div class="font-medium text-gray-900">{org.name}</div>
                  <div class="text-xs text-gray-500 font-mono">{org.slug}</div>
                </td>
                <td class="px-4 py-2 text-sm text-gray-700">{org.country || "—"}</td>
                <td class="px-4 py-2 text-sm text-gray-700">{tier_label(org.prestige_tier)}</td>
                <td class="px-4 py-2 text-sm">
                  <%= if has_url?(org.hero_image_url) do %>
                    <span class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-green-100 text-green-800">
                      ✓
                    </span>
                  <% else %>
                    <span class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-amber-100 text-amber-800">
                      no hero
                    </span>
                  <% end %>
                </td>
                <td class="px-4 py-2 text-right">
                  <button
                    type="button"
                    phx-click="edit_org"
                    phx-value-id={org.id}
                    class="inline-flex items-center rounded-md bg-blue-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-blue-700"
                  >
                    Edit
                  </button>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </.section_card>

    <%= if @editing_org do %>
      <.drawer
        org={@editing_org}
        form={@form}
        suggest_for={@suggest_for}
        suggest_query={@suggest_query}
        suggest_results={@suggest_results}
        suggest_loading?={@suggest_loading?}
      />
    <% end %>
    """
  end

  attr :org, :map, required: true
  attr :form, :any, required: true
  attr :suggest_for, :any, required: true
  attr :suggest_query, :string, required: true
  attr :suggest_results, :map, required: true
  attr :suggest_loading?, :boolean, required: true

  defp drawer(assigns) do
    ~H"""
    <div class="fixed inset-0 z-40 flex" role="dialog" aria-modal="true">
      <div class="fixed inset-0 bg-zinc-900/40" phx-click="close_drawer" aria-label="Close drawer">
      </div>
      <aside class="ml-auto h-full w-full max-w-2xl bg-white shadow-xl flex flex-col z-50 relative">
        <header class="px-6 py-4 border-b border-zinc-200 flex items-center justify-between">
          <div>
            <p class="text-xs uppercase tracking-wide text-zinc-500 font-semibold">Festival</p>
            <h2 class="text-lg font-semibold text-zinc-900">{@org.name}</h2>
            <p class="text-xs text-zinc-500 font-mono">{@org.slug}</p>
          </div>
          <button
            type="button"
            phx-click="close_drawer"
            class="text-zinc-500 hover:text-zinc-900 text-2xl leading-none"
            aria-label="Close"
          >
            ×
          </button>
        </header>

        <div class="flex-1 overflow-y-auto px-6 py-4">
          <.form
            for={@form}
            id={"org-form-#{@org.id}"}
            phx-change="validate"
            phx-submit="save"
            class="space-y-6"
          >
            <%!-- Identity --%>
            <section>
              <h3 class="text-sm font-semibold uppercase tracking-wide text-zinc-500 mb-3">
                Identity
              </h3>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <div>
                  <label class="block text-xs font-medium text-gray-700 mb-1">Name</label>
                  <input
                    type="text"
                    name={@form[:name].name}
                    value={Phoenix.HTML.Form.input_value(@form, :name)}
                    class="w-full rounded-md border-gray-300 text-sm"
                  />
                </div>
                <div>
                  <label class="block text-xs font-medium text-gray-700 mb-1">Country</label>
                  <input
                    type="text"
                    name={@form[:country].name}
                    value={Phoenix.HTML.Form.input_value(@form, :country)}
                    class="w-full rounded-md border-gray-300 text-sm"
                  />
                </div>
                <div>
                  <label class="block text-xs font-medium text-gray-700 mb-1">Abbreviation</label>
                  <input
                    type="text"
                    name={@form[:abbreviation].name}
                    value={Phoenix.HTML.Form.input_value(@form, :abbreviation)}
                    class="w-full rounded-md border-gray-300 text-sm"
                  />
                </div>
                <div>
                  <label class="block text-xs font-medium text-gray-700 mb-1">Founded year</label>
                  <input
                    type="number"
                    name={@form[:founded_year].name}
                    value={Phoenix.HTML.Form.input_value(@form, :founded_year)}
                    class="w-full rounded-md border-gray-300 text-sm"
                  />
                </div>
                <div class="sm:col-span-2">
                  <label class="block text-xs font-medium text-gray-700 mb-1">Website</label>
                  <input
                    type="url"
                    name={@form[:website].name}
                    value={Phoenix.HTML.Form.input_value(@form, :website)}
                    class="w-full rounded-md border-gray-300 text-sm font-mono"
                  />
                </div>
                <div>
                  <label class="block text-xs font-medium text-gray-700 mb-1">Prestige tier</label>
                  <input
                    type="number"
                    name={@form[:prestige_tier].name}
                    value={Phoenix.HTML.Form.input_value(@form, :prestige_tier)}
                    min="0"
                    max="5"
                    class="w-full rounded-md border-gray-300 text-sm"
                  />
                </div>
              </div>
            </section>

            <%!-- Imagery --%>
            <section>
              <h3 class="text-sm font-semibold uppercase tracking-wide text-zinc-500 mb-3">
                Imagery
              </h3>

              <div class="space-y-4">
                <.image_field
                  form={@form}
                  field={:logo_url}
                  label="Logo URL"
                  preview_class="h-16 w-16 object-contain bg-gray-50 rounded border"
                />
                <.image_field
                  form={@form}
                  field={:hero_image_url}
                  label="Hero image URL"
                  preview_class="h-32 w-full object-cover rounded border"
                />
              </div>
            </section>

            <%!-- Stats / external links --%>
            <section>
              <h3 class="text-sm font-semibold uppercase tracking-wide text-zinc-500 mb-3">
                Health & related
              </h3>
              <div class="text-sm text-gray-700 space-y-2">
                <p>Detailed import config + ceremony audit live in their own pages:</p>
                <div class="flex flex-wrap gap-2">
                  <.link
                    navigate={"/admin/festival/#{@org.slug}"}
                    class="inline-flex items-center rounded-md border border-gray-300 px-3 py-1.5 text-xs text-gray-700 hover:bg-gray-50"
                  >
                    Ceremony audit →
                  </.link>
                  <.link
                    navigate="/admin/festival-events"
                    class="inline-flex items-center rounded-md border border-gray-300 px-3 py-1.5 text-xs text-gray-700 hover:bg-gray-50"
                  >
                    Import config →
                  </.link>
                </div>
              </div>
            </section>

            <div class="pt-4 border-t border-gray-200 flex justify-end gap-2">
              <button
                type="button"
                phx-click="close_drawer"
                class="inline-flex items-center rounded-md border border-gray-300 px-4 py-2 text-sm text-gray-700 hover:bg-gray-50"
              >
                Cancel
              </button>
              <button
                type="submit"
                class="inline-flex items-center rounded-md bg-blue-600 px-4 py-2 text-sm font-semibold text-white hover:bg-blue-700"
              >
                Save
              </button>
            </div>
          </.form>
        </div>
      </aside>

      <%= if @suggest_for do %>
        <.suggest_modal
          field={@suggest_for}
          query={@suggest_query}
          results={@suggest_results}
          loading?={@suggest_loading?}
        />
      <% end %>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :preview_class, :string, default: "h-16 w-16 object-contain bg-gray-50 rounded border"

  defp image_field(assigns) do
    value = Phoenix.HTML.Form.input_value(assigns.form, assigns.field) || ""

    assigns = assign(assigns, :value, value)

    ~H"""
    <div>
      <label class="block text-xs font-medium text-gray-700 mb-1">{@label}</label>
      <div class="flex gap-3 items-start">
        <%= if has_url?(@value) do %>
          <img src={@value} alt="" class={@preview_class} />
        <% else %>
          <div class={[@preview_class, "grid place-items-center text-xs text-gray-400 bg-gray-50"]}>
            no image
          </div>
        <% end %>
        <div class="flex-1 space-y-2">
          <input
            type="url"
            name={@form[@field].name}
            value={@value}
            placeholder="https://..."
            class="w-full rounded-md border-gray-300 text-sm font-mono"
          />
          <div class="flex flex-wrap gap-2">
            <button
              type="button"
              phx-click="open_suggest"
              phx-value-field={Atom.to_string(@field)}
              class="inline-flex items-center rounded-md border border-gray-300 bg-white px-3 py-1 text-xs text-gray-700 hover:bg-gray-50"
            >
              ✨ Suggest images
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :field, :atom, required: true
  attr :query, :string, required: true
  attr :results, :map, required: true
  attr :loading?, :boolean, required: true

  defp suggest_modal(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-50 flex items-start justify-center pt-12"
      role="dialog"
      aria-modal="true"
    >
      <div
        class="fixed inset-0 bg-zinc-900/50"
        phx-click="close_suggest"
        aria-label="Close suggest modal"
      >
      </div>
      <div class="relative bg-white rounded-lg shadow-2xl w-full max-w-4xl max-h-[80vh] flex flex-col z-10 mx-4">
        <header class="px-5 py-3 border-b border-zinc-200 flex items-center justify-between">
          <div>
            <h3 class="text-base font-semibold text-zinc-900">Suggest images</h3>
            <p class="text-xs text-zinc-500">
              Click a result to use it for {field_label(@field)}.
            </p>
          </div>
          <button
            type="button"
            phx-click="close_suggest"
            class="text-zinc-500 hover:text-zinc-900 text-2xl leading-none"
            aria-label="Close"
          >
            ×
          </button>
        </header>

        <form phx-change="suggest_search" class="px-5 py-3 border-b border-zinc-100">
          <input
            type="text"
            name="q"
            value={@query}
            placeholder="Search Unsplash, Pexels, Pixabay..."
            phx-debounce="400"
            class="w-full rounded-md border-gray-300 text-sm"
            autofocus
          />
        </form>

        <div class="flex-1 overflow-y-auto px-5 py-3 space-y-6">
          <%= for provider <- [:unsplash, :pexels, :pixabay] do %>
            <% result = Map.get(@results, provider) %>
            <section>
              <h4 class="text-xs font-semibold uppercase tracking-wide text-zinc-500 mb-2">
                {provider_label(provider)}
              </h4>
              <%= case result do %>
                <% nil -> %>
                  <p class="text-xs text-gray-500">
                    {if @loading?, do: "Searching...", else: "Search to see results."}
                  </p>
                <% :disabled -> %>
                  <p class="text-xs text-amber-700">
                    {provider_label(provider)} is disabled — set
                    <code class="font-mono">{env_var(provider)}</code>
                    in .env to enable.
                  </p>
                <% {:error, reason} -> %>
                  <p class="text-xs text-red-700">
                    Error: {format_error(reason)}.
                  </p>
                <% {:ok, []} -> %>
                  <p class="text-xs text-gray-500">No results.</p>
                <% {:ok, items} -> %>
                  <div class="grid grid-cols-2 sm:grid-cols-3 gap-3">
                    <%= for item <- items do %>
                      <button
                        type="button"
                        phx-click="use_image"
                        phx-value-url={item.full_url}
                        class="group block rounded-md border border-gray-200 hover:ring-2 hover:ring-blue-500 hover:border-blue-500 overflow-hidden text-left transition"
                      >
                        <img
                          src={item.thumb_url}
                          alt=""
                          class="w-full h-24 object-cover bg-gray-100"
                        />
                        <div class="px-2 py-1 text-[10px] text-gray-500 truncate">
                          by {item.attribution.name}
                        </div>
                      </button>
                    <% end %>
                  </div>
              <% end %>
            </section>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp tier_label(nil), do: "—"
  defp tier_label(0), do: "tier 0"
  defp tier_label(n) when is_integer(n), do: "tier #{n}"
  defp tier_label(_), do: "—"

  defp field_label(:logo_url), do: "logo"
  defp field_label(:hero_image_url), do: "hero image"
  defp field_label(_), do: "image"

  defp provider_label(:unsplash), do: "Unsplash"
  defp provider_label(:pexels), do: "Pexels"
  defp provider_label(:pixabay), do: "Pixabay"
  defp provider_label(other), do: to_string(other)

  defp env_var(:unsplash), do: "UNSPLASH_ACCESS_KEY"
  defp env_var(:pexels), do: "PEXELS_API_KEY"
  defp env_var(:pixabay), do: "PIXABAY_API_KEY"
  defp env_var(_), do: ""

  defp format_error(:rate_limited), do: "rate limited"
  defp format_error(:timeout), do: "timeout"
  defp format_error({:http, code}), do: "HTTP #{code}"
  defp format_error(other), do: inspect(other) |> String.slice(0, 80)
end
