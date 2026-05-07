defmodule Mix.Tasks.Cinegraph.HealthTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Cinegraph.Health

  describe "normalize_domain/1 (#896 Phase 4.2)" do
    test "accepts all 6 domain names" do
      assert Health.normalize_domain("people") == {:ok, :people}
      assert Health.normalize_domain("movies") == {:ok, :movies}
      assert Health.normalize_domain("festivals") == {:ok, :festivals}
      assert Health.normalize_domain("ratings") == {:ok, :ratings}
      assert Health.normalize_domain("availability") == {:ok, :availability}
      assert Health.normalize_domain("collaborations") == {:ok, :collaborations}
    end

    test "passes nil through as :none" do
      assert Health.normalize_domain(nil) == :none
    end

    test "rejects unknown domains with all 6 valid options listed" do
      assert {:error, msg} = Health.normalize_domain("bogus")
      assert msg =~ "invalid domain"
      assert msg =~ "people"
      assert msg =~ "movies"
      assert msg =~ "festivals"
      assert msg =~ "ratings"
      assert msg =~ "availability"
      assert msg =~ "collaborations"
    end
  end
end
