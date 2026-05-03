defmodule Mix.Tasks.CinegraphImdbListIntegrityAuditTest do
  use Cinegraph.DataCase, async: false

  setup do
    Mix.Task.reenable("cinegraph.audit.imdb_list_integrity")
    Mix.Task.reenable("cinegraph.prod.audit.imdb_list_integrity")
    Mix.Task.reenable("app.start")
    :ok
  end

  test "local integrity task parses json flag" do
    {opts, [], []} = Mix.Tasks.Cinegraph.Audit.ImdbListIntegrity.parse_args(["--json"])

    assert Keyword.get(opts, :json) == true
  end

  test "prod integrity task builds safe ProdRpc expression" do
    expr = Mix.Tasks.Cinegraph.Prod.Audit.ImdbListIntegrity.build_expression()

    assert expr =~ "Cinegraph.Health.ImdbListIntegrityAudit.audit"
    assert expr =~ "Jason.encode!"
  end
end
