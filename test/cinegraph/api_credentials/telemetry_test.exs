defmodule Cinegraph.ApiCredentials.TelemetryTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  setup do
    original = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original) end)
  end

  test "application installs a logger for auth outcomes and costs, excluding arbitrary payloads" do
    for {event, measurements} <- [
          {[:cinegraph, :api_auth, :stop], %{count: 1}},
          {[:cinegraph, :api_auth, :catalog_field], %{request_cost: 1}}
        ] do
      assert Enum.any?(
               :telemetry.list_handlers(event),
               &(&1.id == Cinegraph.Telemetry.ApiAuthLogger)
             )

      for outcome <- [:ok, :revoked, :wrong_secret] do
        log =
          capture_log(fn ->
            :telemetry.execute(event, Map.put(measurements, :secret, "must-not-log"), %{
              outcome: outcome,
              auth_kind: :legacy,
              client_id: "legacy",
              key_id: "legacy",
              client_slug: "legacy-shared-key",
              authorization: "Bearer must-not-log",
              token: "must-not-log"
            })
          end)

        assert log =~ "catalog_api"
        assert log =~ "legacy-shared-key"
        assert log =~ Atom.to_string(outcome)
        refute log =~ "must-not-log"
        refute log =~ "authorization"
      end
    end
  end
end
