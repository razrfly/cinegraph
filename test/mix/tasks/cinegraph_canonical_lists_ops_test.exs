defmodule Mix.Tasks.CinegraphCanonicalListsOpsTest do
  use Cinegraph.DataCase, async: false

  setup do
    Mix.Task.reenable("cinegraph.audit.canonical_lists")
    Mix.Task.reenable("cinegraph.canonical.enqueue_refresh")
    Mix.Task.reenable("app.start")
    :ok
  end

  test "local audit task normalizes option aliases" do
    assert Mix.Tasks.Cinegraph.Audit.CanonicalLists.audit_opts(
             "blank-only": true,
             "stale-days": 14,
             json: true
           ) == [stale_days: 14, blank_only: true]
  end

  test "prod audit builds safe ProdRpc expression" do
    expr =
      Mix.Tasks.Cinegraph.Prod.Audit.CanonicalLists.build_expression(
        "blank-only": true,
        "stale-days": 90,
        json: true
      )

    assert expr =~ "Cinegraph.Health.CanonicalListsAudit.audit"
    assert expr =~ "blank_only: true"
    assert expr =~ "stale_days: 90"
  end

  test "enqueue task normalizes option aliases" do
    opts =
      Mix.Tasks.Cinegraph.Canonical.EnqueueRefresh.refresh_opts(
        "blank-only": true,
        "stale-days": 90,
        "dry-run": true,
        limit: 10
      )

    assert Keyword.get(opts, :blank_only) == true
    assert Keyword.get(opts, :stale_days) == 90
    assert Keyword.get(opts, :dry_run) == true
    assert Keyword.get(opts, :limit) == 10
  end

  test "prod enqueue builds run expression" do
    expr =
      Mix.Tasks.Cinegraph.Prod.Canonical.EnqueueRefresh.build_expression(
        "blank-only": true,
        limit: 10,
        "dry-run": true
      )

    assert expr =~ "Cinegraph.Maintenance.RefreshCanonicalLists.run"
    assert expr =~ "blank_only: true"
    assert expr =~ "limit: 10"
    assert expr =~ "dry_run: true"
    assert expr =~ "{:ok, stats} -> IO.puts(Jason.encode!(stats))"
  end

  test "enqueue task fails clearly without selector" do
    assert_raise ArgumentError, fn ->
      Mix.Tasks.Cinegraph.Canonical.EnqueueRefresh.run(["--dry-run"])
    end
  end
end
