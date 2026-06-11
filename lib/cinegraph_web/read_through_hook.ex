defmodule CinegraphWeb.ReadThroughHook do
  @moduledoc """
  Shared read-through trigger for the movie/person show LiveViews (#1108 §10b).

  On the **connected** socket only, schedules a fire-and-forget freshness refresh
  so the page self-freshens without blocking render (the static first render
  never fires it). Use from both `handle_params` (schedule) and `handle_info`
  (run):

      socket |> ReadThroughHook.schedule(%{type: :movie, id: movie.id})

      def handle_info({:read_through, entity}, socket),
        do: {:noreply, ReadThroughHook.run(socket, entity)}
  """
  import Phoenix.LiveView, only: [connected?: 1]

  alias Cinegraph.Freshness.ReadThrough

  @doc "Schedule a read-through pass for `entity` (`%{type:, id:}`) — connected socket only."
  def schedule(socket, %{type: _, id: _} = entity) do
    if connected?(socket), do: send(self(), {:read_through, entity})
    socket
  end

  def schedule(socket, _entity), do: socket

  @doc "Run the read-through pass (fire-and-forget; called from handle_info)."
  def run(socket, entity) do
    ReadThrough.refresh_if_stale(entity)
    socket
  rescue
    e ->
      require Logger
      Logger.warning("ReadThroughHook: #{Exception.message(e)}")
      socket
  end
end
