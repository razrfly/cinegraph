defmodule Cinegraph.ApiCredentials.LegacyTest do
  use ExUnit.Case, async: false

  alias Cinegraph.ApiCredentials.Legacy

  setup do
    key = Application.get_env(:cinegraph, :legacy_api_key)
    expiry = Application.get_env(:cinegraph, :legacy_api_key_expires_at)

    on_exit(fn ->
      restore(:legacy_api_key, key)
      restore(:legacy_api_key_expires_at, expiry)
    end)

    :ok
  end

  test "requires a configured key and explicit unexpired deadline" do
    now = DateTime.utc_now()
    Application.delete_env(:cinegraph, :legacy_api_key)
    Application.delete_env(:cinegraph, :legacy_api_key_expires_at)
    assert {:error, :unconfigured} = Legacy.authenticate("anything", now)

    Application.put_env(:cinegraph, :legacy_api_key, "legacy-secret")
    assert {:error, :unconfigured} = Legacy.authenticate("legacy-secret", now)

    Application.put_env(:cinegraph, :legacy_api_key_expires_at, now)
    assert {:error, :expired} = Legacy.authenticate("legacy-secret", now)

    Application.put_env(:cinegraph, :legacy_api_key_expires_at, DateTime.add(now, 1))
    assert {:error, :invalid} = Legacy.authenticate("wrong", now)
    assert {:ok, %{kind: :legacy}} = Legacy.authenticate("legacy-secret", now)
  end

  defp restore(key, nil), do: Application.delete_env(:cinegraph, key)
  defp restore(key, value), do: Application.put_env(:cinegraph, key, value)
end
