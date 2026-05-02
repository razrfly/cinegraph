defmodule Mix.Tasks.CinegraphImdbListPaginationAuditTest do
  use Cinegraph.DataCase, async: false

  setup do
    Mix.Task.reenable("cinegraph.audit.imdb_list_pagination")
    Mix.Task.reenable("cinegraph.prod.audit.imdb_list_pagination")
    Mix.Task.reenable("app.start")
    :ok
  end

  test "local audit task normalizes option aliases" do
    opts =
      Mix.Tasks.Cinegraph.Audit.ImdbListPagination.audit_opts(
        list: "cult_movies_400",
        "list-id": "ls053182933",
        starts: "1,76,151",
        "page-wait": 7_500,
        "ajax-wait": false,
        scroll: true,
        "scroll-interval": 800,
        json: true
      )

    assert Keyword.get(opts, :list) == "cult_movies_400"
    assert Keyword.get(opts, :list_id) == "ls053182933"
    assert Keyword.get(opts, :starts) == "1,76,151"
    assert Keyword.get(opts, :page_wait) == 7_500
    assert Keyword.get(opts, :ajax_wait) == false
    assert Keyword.get(opts, :scroll) == true
    assert Keyword.get(opts, :scroll_interval) == 800
    refute Keyword.has_key?(opts, :json)
  end

  test "parse_args accepts documented local flags" do
    {opts, [], []} =
      Mix.Tasks.Cinegraph.Audit.ImdbListPagination.parse_args([
        "--list-id",
        "ls053182933",
        "--starts",
        "1,76",
        "--page-wait",
        "7500",
        "--no-ajax-wait",
        "--scroll",
        "--scroll-interval",
        "800",
        "--json"
      ])

    assert Keyword.get(opts, :list_id) == "ls053182933"
    assert Keyword.get(opts, :starts) == "1,76"
    assert Keyword.get(opts, :page_wait) == 7_500
    assert Keyword.get(opts, :ajax_wait) == false
    assert Keyword.get(opts, :scroll) == true
    assert Keyword.get(opts, :scroll_interval) == 800
    assert Keyword.get(opts, :json) == true
  end

  test "prod audit builds safe ProdRpc expression" do
    expr =
      Mix.Tasks.Cinegraph.Prod.Audit.ImdbListPagination.build_expression(
        list: "cult_movies_400",
        starts: "1,76,151",
        "page-wait": 7_500,
        "ajax-wait": false,
        scroll: true,
        "scroll-interval": 800,
        json: true
      )

    assert expr =~ "Cinegraph.Health.ImdbListPaginationAudit.audit"
    assert expr =~ ~s|list: "cult_movies_400"|
    assert expr =~ ~s|starts: "1,76,151"|
    assert expr =~ "page_wait: 7500"
    assert expr =~ "ajax_wait: false"
    assert expr =~ "scroll: true"
    assert expr =~ "scroll_interval: 800"
  end

  test "audit module fails clearly without a list selector" do
    assert_raise ArgumentError, "provide either --list or --list-id", fn ->
      Cinegraph.Health.ImdbListPaginationAudit.audit(
        starts: [1],
        fetcher: fn _, _, _ -> {:ok, ""} end
      )
    end
  end
end
