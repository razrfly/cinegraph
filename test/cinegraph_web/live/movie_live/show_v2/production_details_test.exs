defmodule CinegraphWeb.MovieLive.ShowV2.ProductionDetailsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CinegraphWeb.MovieLive.ShowV2.ProductionDetails

  describe "production_details/1" do
    test "preserves the em dash fallback for missing and blank names" do
      html =
        render_component(&ProductionDetails.production_details/1,
          production_companies: [
            %{id: 1, name: nil},
            %{id: 2, name: "   "}
          ]
        )

      assert length(Regex.scan(~r/—/, html)) == 2
      refute html =~ ~r/>\s+-\s*</
    end
  end
end
