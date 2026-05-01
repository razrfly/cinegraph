defmodule CinegraphWeb.Components.PeopleMatch do
  @moduledoc """
  Controls for choosing how selected people are matched in movie filters.
  """

  use Phoenix.Component

  attr :id, :string, required: true
  attr :selected_people, :list, default: []
  attr :people_match, :string, default: nil

  def controls(assigns) do
    ~H"""
    <div :if={length(@selected_people) >= 2} id={@id} class="mt-3">
      <div class="grid grid-cols-2 gap-2" role="group" aria-label="People matching">
        <button
          type="button"
          phx-click="set_people_match"
          phx-value-match="any"
          aria-pressed={@people_match != "all"}
          class={[
            "rounded-lg border px-3 py-2 text-[12.5px] font-semibold transition-colors",
            if(@people_match == "all",
              do: "bg-mist-50 border-mist-950/15 text-mist-700 hover:bg-mist-950/[0.025]",
              else: "bg-mist-950 border-mist-950 text-mist-50"
            )
          ]}
        >
          Any person
        </button>
        <button
          type="button"
          phx-click="set_people_match"
          phx-value-match="all"
          aria-pressed={@people_match == "all"}
          class={[
            "rounded-lg border px-3 py-2 text-[12.5px] font-semibold transition-colors",
            if(@people_match == "all",
              do: "bg-mist-950 border-mist-950 text-mist-50",
              else: "bg-mist-50 border-mist-950/15 text-mist-700 hover:bg-mist-950/[0.025]"
            )
          ]}
        >
          All together
        </button>
      </div>
    </div>
    """
  end
end
