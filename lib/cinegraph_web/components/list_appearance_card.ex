defmodule CinegraphWeb.Components.ListAppearanceCard do
  @moduledoc false

  use CinegraphWeb, :html

  alias CinegraphWeb.MovieLive.ShowV2.ListAppearance
  alias CinegraphWeb.NeutralV2Components

  attr :list, :map, required: true

  def card(assigns) do
    assigns = assign(assigns, :href, ListAppearance.href(assigns.list))

    ~H"""
    <%= if @href do %>
      <.link
        navigate={@href}
        class="group block overflow-hidden rounded-lg border border-mist-950/10 bg-mist-50 text-inherit no-underline transition-shadow hover:shadow-[0_8px_24px_rgba(20,18,15,.08)]"
      >
        <.card_inner list={@list} />
      </.link>
    <% else %>
      <div class="overflow-hidden rounded-lg border border-mist-950/10 bg-mist-50">
        <.card_inner list={@list} />
      </div>
    <% end %>
    """
  end

  attr :list, :map, required: true

  defp card_inner(assigns) do
    assigns = assign(assigns, :short_name, non_blank(assigns.list.short_name))

    ~H"""
    <% image = ListAppearance.image(@list) %>
    <div class={[
      "relative aspect-[8/5] overflow-hidden bg-gradient-to-br",
      ListAppearance.visual_class(@list)
    ]}>
      <img
        :if={image}
        src={image}
        alt=""
        loading="lazy"
        class="h-full w-full object-cover transition-transform duration-300 group-hover:scale-[1.03]"
      />
      <div
        :if={!image}
        class="grid h-full w-full place-items-center px-5 text-center font-display italic text-[34px] leading-none text-mist-950"
      >
        {ListAppearance.initials(@list)}
      </div>
      <div class="absolute bottom-3 right-3 rounded-md bg-mist-50/90 px-2 py-1 text-[13px] font-semibold text-mist-950 shadow-sm">
        {ListAppearance.rank(@list)}
      </div>
    </div>
    <div class="px-4 py-4">
      <div
        :if={eyebrow = ListAppearance.eyebrow(@list)}
        class="mb-2 text-[10.5px] font-semibold uppercase tracking-[.08em] text-mist-500"
      >
        {eyebrow}
      </div>
      <h3 class="line-clamp-2 text-[17px] font-semibold leading-snug text-mist-950">
        {ListAppearance.title(@list)}
      </h3>
      <div class="mt-4 flex flex-wrap gap-2">
        <NeutralV2Components.n_pill tone="ink" size="xs">
          {ListAppearance.rank(@list)}
        </NeutralV2Components.n_pill>
        <NeutralV2Components.n_pill :if={@short_name} tone="neutral" size="xs">
          {@short_name}
        </NeutralV2Components.n_pill>
      </div>
      <div :if={ListAppearance.href(@list)} class="mt-4 text-[12px] font-semibold text-mist-950">
        View list →
      </div>
    </div>
    """
  end

  defp non_blank(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp non_blank(_value), do: nil
end
