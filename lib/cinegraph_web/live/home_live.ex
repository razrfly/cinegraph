defmodule CinegraphWeb.HomeLive do
  use CinegraphWeb, :live_view

  alias Cinegraph.Homepage

  attr :person, :map, required: true

  def person_teaser(assigns) do
    ~H"""
    <.link navigate={@person.href} class="block text-center text-inherit no-underline">
      <div class="mx-auto h-16 w-16 overflow-hidden rounded-full border border-mist-950/10 bg-mist-100">
        <img
          :if={@person.image_url}
          src={@person.image_url}
          alt=""
          class="h-full w-full object-cover"
        />
      </div>
      <div class="mt-2 text-[13px] font-semibold leading-tight text-mist-950">{@person.name}</div>
      <div class="mt-1 text-[11.5px] text-mist-600">{@person.role}</div>
    </.link>
    """
  end

  attr :card, :map, default: nil

  def festival_teaser(assigns) do
    ~H"""
    <.link
      :if={@card}
      navigate={@card.href}
      class="block rounded-[7px] border border-mist-950/10 bg-white px-4 py-4 text-inherit no-underline"
    >
      <div class="text-[10.5px] font-semibold uppercase tracking-[.08em] text-mist-500">
        {@card.eyebrow}
      </div>
      <div class="mt-2 text-[15px] font-semibold leading-snug text-mist-950">{@card.title}</div>
      <p class="mt-2 text-[12.5px] leading-relaxed text-mist-700">{@card.description}</p>
    </.link>
    """
  end

  def format_home_score(nil), do: "—"

  def format_home_score(score) when is_float(score),
    do: :erlang.float_to_binary(score, decimals: 1)

  def format_home_score(score), do: to_string(score)

  @lets_you_features [
    %{
      icon: "🎬",
      title: "Browse every film, scored six different ways.",
      href: "/movies"
    },
    %{
      icon: "🏆",
      title: "Pick by festival or list — Cannes, Sundance, the canon, your way.",
      href: "/awards"
    },
    %{
      icon: "🔍",
      title: "Tune your own ranking with the 6-lens discovery dial.",
      href: "/movies/discover"
    },
    %{
      icon: "🤝",
      title: "See who's worked with whom in our six-degrees graph.",
      href: "/six-degrees"
    },
    %{
      icon: "🎯",
      title: "Spot the disagreements between critics and audiences.",
      href: "/explore/disparity"
    },
    %{
      icon: "🏪",
      title: "Ask the Video Clerk for a pick that explains itself.",
      href: "/video-clerk"
    }
  ]

  def lets_you_features, do: @lets_you_features

  @impl true
  def mount(_params, _session, socket) do
    snapshot = Homepage.snapshot()
    seeds = Homepage.clerk_demo_seeds()
    initial_seed_key = (List.first(seeds) || %{key: nil}).key

    clerk_result = initial_seed_key && Homepage.clerk_demo(initial_seed_key)

    {:ok,
     socket
     |> assign(:page_title, "Cinegraph")
     |> assign(:meta_title, "Cinegraph · The video store clerk for the streaming era")
     |> assign(
       :meta_description,
       "We score every film six different ways — by critics, audiences, festivals, the canon, the people who made it, and the box office."
     )
     |> assign(:canonical_url, "https://cinegraph.org/")
     |> assign(:active_nav, "Home")
     |> assign(:snapshot, snapshot)
     |> assign(:lens_definitions, Homepage.lens_definitions())
     |> assign(:lets_you_features, @lets_you_features)
     |> assign(:clerk_seeds, seeds)
     |> assign(:active_clerk_seed, initial_seed_key)
     |> assign(:clerk_result, clerk_result)}
  end

  @impl true
  def handle_event("clerk_demo", %{"seed" => seed_key}, socket) do
    {:noreply,
     socket
     |> assign(:active_clerk_seed, seed_key)
     |> assign(:clerk_result, Homepage.clerk_demo(seed_key))}
  end

  def handle_event("shuffle_six_degrees", _, socket) do
    snapshot = put_in(socket.assigns.snapshot.six_degrees, Homepage.six_degrees_teaser_random())
    {:noreply, assign(socket, :snapshot, snapshot)}
  end
end
