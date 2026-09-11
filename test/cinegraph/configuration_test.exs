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
end
