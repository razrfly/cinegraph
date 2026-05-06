defmodule Cinegraph.Admin.AuditRegistry do
  @moduledoc """
  Single source of truth for every `mix cinegraph.audit.*` task that's
  surfaced as a UI tab on `/admin/audits` (#880 Phase 3).

  Mirrors the `Cinegraph.Admin.JobRegistry` pattern from Phase 1: a registry +
  parity test prevents the admin tabs page from drifting out of sync with the
  set of audit modules.

  ## Adding a new audit

  1. Make sure the module exposes `audit(opts \\ [])` (or another callable
     returning a JSON-serializable map).
  2. Add an entry below.
  3. Run the test suite — `audit_registry_test.exs` will fail loudly if the
     module isn't loadable or the function arity doesn't match.

  Phase 4 of #880 promoted `audit_people_scores` from Mix-only to library;
  it now appears alongside the other audits.
  """

  alias Cinegraph.Health
  alias Cinegraph.Maintenance

  @typedoc """
  - `id` — stable atom for `?audit=:id` URL param
  - `label` — human-readable tab name
  - `module` — implementing module
  - `audit_fun` — function name (`:audit` or `:inspect`)
  - `arity` — `:zero` (no args), `:opts` (keyword opts), `:required` (positional required arg)
  - `args` — keyword list of default opts
  - `description` — one-line summary
  - `speed` — `:fast` (DB-only) or `:slow` (HTTP, ≥1s typical)
  - `destination` — drilldown domain hint
  """
  @type entry :: %{
          id: atom(),
          label: String.t(),
          module: module(),
          audit_fun: atom(),
          arity: :zero | :opts | :required,
          args: keyword(),
          description: String.t(),
          speed: :fast | :slow,
          destination: atom()
        }

  @entries [
    %{
      id: :availability,
      label: "Availability coverage",
      module: Health.AvailabilityAudit,
      audit_fun: :audit,
      arity: :opts,
      args: [],
      description: "Watch-availability coverage, freshness, errors, queue state.",
      speed: :fast,
      destination: :availability
    },
    %{
      id: :canonical_lists,
      label: "Canonical lists",
      module: Health.CanonicalListsAudit,
      audit_fun: :audit,
      arity: :opts,
      args: [],
      description: "IMDb canonical-list freshness and movie coverage.",
      speed: :fast,
      destination: :imports
    },
    %{
      id: :imdb_event_id,
      label: "IMDb event lookup",
      module: Health.ImdbEventInspector,
      audit_fun: :inspect,
      arity: :required,
      args: [],
      description: "Diagnose a festival's IMDb event_id (live HTTP fetch).",
      speed: :slow,
      destination: :festivals
    },
    %{
      id: :imdb_list_integrity,
      label: "IMDb list integrity",
      module: Health.ImdbListIntegrityAudit,
      audit_fun: :audit,
      arity: :opts,
      args: [],
      description: "Per-list integrity: blank, discontinuous, partial, complete.",
      speed: :fast,
      destination: :imports
    },
    %{
      id: :imdb_list_pagination,
      label: "IMDb list pagination",
      module: Health.ImdbListPaginationAudit,
      audit_fun: :audit,
      arity: :opts,
      args: [],
      description: "Per-window IMDb list fetch diagnostics (live HTTP).",
      speed: :slow,
      destination: :imports
    },
    %{
      id: :queue_failures,
      label: "Queue failures",
      module: Health.QueueFailures,
      audit_fun: :audit,
      arity: :opts,
      args: [days: 7],
      description: "Recent Oban discards classified by error pattern.",
      speed: :fast,
      destination: :system
    },
    %{
      id: :year_discovery,
      label: "Year discovery",
      module: Health.YearDiscovery,
      audit_fun: :audit,
      arity: :opts,
      args: [days: 7],
      description: "Per-festival year-discovery import health.",
      speed: :fast,
      destination: :festivals
    },
    %{
      id: :companies,
      label: "Production companies",
      module: Maintenance.Companies,
      audit_fun: :audit,
      arity: :opts,
      args: [],
      description: "Production-company logo, slug, and metadata coverage.",
      speed: :fast,
      destination: :movies
    },
    %{
      id: :people_scores,
      label: "Auteurs ground-truth scores",
      module: Health.PeopleScoresAudit,
      audit_fun: :audit,
      arity: :opts,
      args: [],
      description: "Auteurs score audit against a curated 15-film ground truth.",
      speed: :fast,
      destination: :people
    }
  ]

  @doc "All registered audit entries."
  @spec all() :: [entry()]
  def all, do: @entries

  @doc "Look up an entry by id. Returns `nil` if not found."
  @spec by_id(atom()) :: entry() | nil
  def by_id(id) when is_atom(id), do: Enum.find(@entries, &(&1.id == id))

  @doc "Filter entries by destination domain."
  @spec by_destination(atom()) :: [entry()]
  def by_destination(domain), do: Enum.filter(@entries, &(&1.destination == domain))

  @doc "Filter entries by speed."
  @spec by_speed(atom()) :: [entry()]
  def by_speed(speed), do: Enum.filter(@entries, &(&1.speed == speed))

  @doc """
  Run an audit entry, applying its registered defaults plus any caller-supplied
  args.

  Returns `{:ok, result_map}` on success, `{:error, reason}` on failure or
  unknown id.

  For `arity: :required` entries (e.g., :imdb_event_id needing event_id), the
  caller MUST supply the positional arg via the `:required_arg` option.
  """
  @spec run(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(id, runtime_opts \\ []) when is_atom(id) do
    case by_id(id) do
      nil ->
        {:error, :unknown_audit}

      entry ->
        do_run(entry, runtime_opts)
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp do_run(%{arity: :zero, module: m, audit_fun: f}, _opts) do
    normalize_result(apply(m, f, []))
  end

  defp do_run(%{arity: :opts} = entry, runtime_opts) do
    opts = Keyword.merge(entry.args, runtime_opts)
    normalize_result(apply(entry.module, entry.audit_fun, [opts]))
  end

  defp do_run(%{arity: :required} = entry, runtime_opts) do
    case Keyword.fetch(runtime_opts, :required_arg) do
      {:ok, arg} ->
        opts = Keyword.merge(entry.args, Keyword.delete(runtime_opts, :required_arg))
        normalize_result(apply(entry.module, entry.audit_fun, [arg, opts]))

      :error ->
        {:error, :missing_required_arg}
    end
  end

  # Normalize different return conventions. Health audits return a bare map;
  # Maintenance.Companies returns `{:ok, map}`; failing audits may return
  # `{:error, reason}`. Surface a single shape to the LiveView.
  defp normalize_result({:ok, %{} = map}), do: {:ok, map}
  defp normalize_result({:error, _} = err), do: err
  defp normalize_result(%{} = map), do: {:ok, map}
  defp normalize_result(other), do: {:error, {:unexpected_audit_shape, other}}
end
