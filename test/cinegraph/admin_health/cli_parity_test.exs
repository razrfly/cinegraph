defmodule Cinegraph.AdminHealth.CliParityTest do
  @moduledoc """
  CLI parity contract for `/admin/health` (#745 Phase 3.2).

  Locks the principle from #722: every metric or write-action visible on
  the dashboard must also be reachable from a documented `mix cinegraph.*`
  command. This test fails when:

  - a new dashboard surface is added without registering a CLI counterpart, OR
  - a registered CLI task no longer exists (e.g. renamed without updating
    the registry), OR
  - a registered task lacks `@shortdoc` (so it doesn't show up in `mix help`).

  ## How to add a new dashboard surface

  1. Build the LiveView panel / drawer button for the new metric.
  2. Add the matching `mix cinegraph.<thing>` task with `@shortdoc`.
  3. Register the pair in `@dashboard_surfaces` below — both fields are
     required.

  ## Why a curated registry (not auto-introspection)

  Module introspection can miss dashboard surfaces that don't surface the
  metric name in their tests, and it can't distinguish "intentional
  read-only surface" from "missing CLI." The registry is small (~10 entries)
  and explicit; CI catches drift.
  """
  use ExUnit.Case, async: true

  # Each entry pairs a dashboard surface (label only — string for human
  # readability) with the canonical `mix cinegraph.*` task module that
  # provides its CLI counterpart.
  @dashboard_surfaces [
    # ---- Read surfaces ----
    %{
      surface: "Hero verdict band (worst-check + status rollup)",
      task: Mix.Tasks.Cinegraph.Health
    },
    %{
      surface: "Today's activity strip (movies+/people+/etc.)",
      task: Mix.Tasks.Cinegraph.Activity
    },
    %{
      surface: "Domain drift cards (people/movies/festivals/ratings)",
      task: Mix.Tasks.Cinegraph.Drift
    },
    %{
      surface: "Queue strip (per-Oban-queue counts)",
      task: Mix.Tasks.Cinegraph.Queues
    },
    %{
      surface: "30-day completeness chart",
      task: Mix.Tasks.Cinegraph.Completeness
    },

    # ---- Read surfaces over rpc (production) ----
    %{
      surface: "Hero verdict — read live prod numbers from dev",
      task: Mix.Tasks.Cinegraph.Prod.Health
    },
    %{
      surface: "Completeness — live prod",
      task: Mix.Tasks.Cinegraph.Prod.Completeness
    },
    %{
      surface: "Queues — live prod",
      task: Mix.Tasks.Cinegraph.Prod.Queues
    },
    %{
      surface: "Today's activity — live prod",
      task: Mix.Tasks.Cinegraph.Prod.Activity
    },

    # ---- Drawer write actions ----
    %{
      surface: "People drawer 'Queue TMDb refresh' button",
      task: Mix.Tasks.Cinegraph.Refresh.Person
    },
    %{
      surface: "Ratings drawer 'Queue OMDb refresh' button",
      task: Mix.Tasks.Cinegraph.Refresh.Omdb
    }
  ]

  describe "CLI parity contract" do
    test "every dashboard surface has a mix-task counterpart" do
      missing =
        Enum.filter(@dashboard_surfaces, fn entry ->
          not Code.ensure_loaded?(entry.task)
        end)

      assert missing == [],
             "Dashboard surfaces with missing CLI tasks:\n" <>
               Enum.map_join(missing, "\n", fn e ->
                 "  - #{e.surface} → expected #{inspect(e.task)} (module not loaded)"
               end)
    end

    test "every registered task has a @shortdoc (visible in `mix help`)" do
      missing_shortdoc =
        Enum.filter(@dashboard_surfaces, fn entry ->
          Code.ensure_loaded?(entry.task) and
            not has_shortdoc?(entry.task)
        end)

      assert missing_shortdoc == [],
             "Tasks without @shortdoc (won't show up in `mix help`):\n" <>
               Enum.map_join(missing_shortdoc, "\n", fn e ->
                 "  - #{inspect(e.task)} (#{e.surface})"
               end)
    end

    test "every registered task implements `Mix.Task` behaviour" do
      not_a_task =
        Enum.filter(@dashboard_surfaces, fn entry ->
          Code.ensure_loaded?(entry.task) and
            not implements_mix_task?(entry.task)
        end)

      assert not_a_task == [],
             "Modules registered as tasks but not implementing Mix.Task:\n" <>
               Enum.map_join(not_a_task, "\n", fn e ->
                 "  - #{inspect(e.task)}"
               end)
    end
  end

  # ===== private =====

  defp has_shortdoc?(module) do
    case Mix.Task.shortdoc(module) do
      nil -> false
      "" -> false
      doc when is_binary(doc) -> true
    end
  rescue
    _ -> false
  end

  defp implements_mix_task?(module) do
    behaviours = module.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
    Mix.Task in behaviours
  rescue
    _ -> false
  end
end
