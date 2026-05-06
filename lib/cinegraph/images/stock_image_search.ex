defmodule Cinegraph.Images.StockImageSearch do
  @moduledoc """
  Parallel orchestrator for the festival admin "Suggest images" picker
  (#880 Phase 2).

  Hits Unsplash, Pexels, and Pixabay concurrently via the application task
  supervisor. Returns a map keyed by provider with each value being:

  - `{:ok, [result()]}` — list of normalized results
  - `:disabled` — provider's env var is unset
  - `{:error, reason}` — HTTP failure, decode failure, or timeout

  The caller (LiveView modal) decides what to render per provider — usually
  shows results, hides disabled providers, and shows a retry hint on error.

  ## Caching

  Results are cached for 10 minutes by `(provider, query, per_provider)` in
  the existing `:movies_cache` Cachex. Rapid-fire retypes from the modal's
  debounced input don't pound the upstream APIs.
  """

  alias Cinegraph.Images.Providers

  @providers [:unsplash, :pexels, :pixabay]
  @timeout_ms 5_000
  @cache_ttl :timer.minutes(10)
  @cache_name :movies_cache
  @task_supervisor Cinegraph.Images.TaskSupervisor

  @type provider :: :unsplash | :pexels | :pixabay
  @type provider_result ::
          {:ok, [Cinegraph.Images.Providers.Unsplash.result()]}
          | :disabled
          | {:error, term()}

  @doc """
  Searches every configured stock-image provider and returns provider-keyed results.

  Each provider runs under `Cinegraph.Images.TaskSupervisor` and is bounded by a
  five-second timeout. Individual provider results are cached in `:movies_cache`
  for ten minutes.
  """
  @spec search(String.t(), pos_integer()) :: %{provider() => provider_result()}
  def search(query, per_provider \\ 6) when is_binary(query) and is_integer(per_provider) do
    @task_supervisor
    |> Task.Supervisor.async_stream_nolink(
      @providers,
      fn provider -> cached_search(provider, query, per_provider) end,
      timeout: @timeout_ms,
      on_timeout: :kill_task,
      max_concurrency: length(@providers)
    )
    |> Enum.zip(@providers)
    |> Enum.map(fn
      {{:ok, result}, provider} -> {provider, result}
      {{:exit, :timeout}, provider} -> {provider, {:error, :timeout}}
      {{:exit, reason}, provider} -> {provider, {:error, {:exit, reason}}}
    end)
    |> Map.new()
  end

  @doc "Returns the list of providers in display order."
  @spec providers() :: [provider()]
  def providers, do: @providers

  defp cached_search(provider, query, per_provider) do
    key = {__MODULE__, provider, query, per_provider}

    case Cachex.fetch(
           @cache_name,
           key,
           fn -> {:commit, run_provider(provider, query, per_provider)} end,
           ttl: @cache_ttl
         ) do
      {:ok, value} -> value
      {:commit, value} -> value
      _ -> run_provider(provider, query, per_provider)
    end
  rescue
    _ -> run_provider(provider, query, per_provider)
  end

  defp run_provider(:unsplash, query, n), do: Providers.Unsplash.search(query, n)
  defp run_provider(:pexels, query, n), do: Providers.Pexels.search(query, n)
  defp run_provider(:pixabay, query, n), do: Providers.Pixabay.search(query, n)
end
