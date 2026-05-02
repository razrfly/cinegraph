defmodule CinegraphWeb.MovieLive.ShowV2.DataTest do
  use ExUnit.Case, async: true

  alias CinegraphWeb.MovieLive.ShowV2.Data

  describe "browser_region/1" do
    test "extracts explicit regions after script subtags" do
      assert Data.browser_region(%{"browser_locale" => "zh-Hant-TW"}) == ["TW"]
      assert Data.browser_region(%{"browser_locale" => "sr-Latn-RS"}) == ["RS"]
    end

    test "keeps language fallback when no explicit region is present" do
      assert Data.browser_region(%{"browser_locale" => "fr"}) == ["FR"]
    end
  end
end
