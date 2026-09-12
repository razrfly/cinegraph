defmodule Cinegraph.ConfigurationTest do
  use ExUnit.Case, async: true

  alias Cinegraph.Configuration

  test "accepts a non-blank required secret without changing it" do
    assert Configuration.require_non_blank!("SECRET", " value ") == " value "
  end

  test "rejects empty and whitespace-only required secrets" do
    assert_raise ArgumentError, "SECRET must not be blank", fn ->
      Configuration.require_non_blank!("SECRET", "")
    end

    assert_raise ArgumentError, "SECRET must not be blank", fn ->
      Configuration.require_non_blank!("SECRET", "  \n\t")
    end
  end

  test "local API auth bypass is explicit and impossible in production" do
    assert Configuration.api_auth_local_bypass!(:dev, "true")
    refute Configuration.api_auth_local_bypass!(:dev, nil)
    refute Configuration.api_auth_local_bypass!(:prod, "false")

    assert_raise ArgumentError,
                 "CINEGRAPH_API_AUTH_LOCAL_BYPASS is forbidden in production",
                 fn ->
                   Configuration.api_auth_local_bypass!(:prod, "true")
                 end

    assert_raise ArgumentError, "CINEGRAPH_API_AUTH_LOCAL_BYPASS must be true or false", fn ->
      Configuration.api_auth_local_bypass!(:dev, "sometimes")
    end
  end
end
