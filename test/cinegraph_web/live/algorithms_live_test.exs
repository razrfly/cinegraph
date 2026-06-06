defmodule CinegraphWeb.AlgorithmsLiveTest do
  use CinegraphWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinegraph.Movies.MovieList
  alias Cinegraph.Repo

  defp displayable_list!(attrs) do
    %MovieList{}
    |> MovieList.changeset(
      Map.merge(
        %{
          source_key: "tlist_#{System.unique_integer([:positive])}",
          name: "Test List #{System.unique_integer([:positive])}",
          source_type: "imdb",
          source_url: "https://example.com/l",
          slug: "test-list-#{System.unique_integer([:positive])}",
          active: true,
          display_order: 1
        },
        Map.new(attrs)
      )
    )
    |> Repo.insert!()
  end

  describe "/algorithms" do
    test "renders the honest index chrome + methodology", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/algorithms")

      assert html =~ "Algorithms."
      assert html =~ "Prediction Reliability"
      assert html =~ "How we measure"
      # honesty furniture
      assert html =~ "Wilson-95 lower bound"
      assert html =~ "not metadata-predictable"
    end

    test "a list with no active model renders as an honest 'not predictable' card", %{conn: conn} do
      list = displayable_list!(name: "Lonely Cult List")

      {:ok, _view, html} = live(conn, ~p"/algorithms")

      assert html =~ "Lonely Cult List"
      assert html =~ "serve a prediction for this list"

      refute is_nil(Repo.get(MovieList, list.id))
    end
  end

  describe "/algorithms/:slug (show)" do
    test "an unserved list renders the honest 'not metadata-predictable' detail", %{conn: conn} do
      list =
        displayable_list!(
          name: "Frozen Taste List",
          slug: "frozen-taste-#{System.unique_integer([:positive])}"
        )

      {:ok, _view, html} = live(conn, ~p"/algorithms/#{list.slug}")

      assert html =~ "Frozen Taste List"
      assert html =~ "Not metadata-predictable"

      assert html =~ "We don't serve a prediction for this list" or
               html =~ "We don&#39;t serve a prediction for this list"

      assert html =~ "Back to all algorithms"
      # the weight breakdown is served-only
      refute html =~ "What drives the prediction"
    end

    test "an unknown slug redirects back to the index", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/algorithms"}}} =
               live(conn, ~p"/algorithms/no-such-list-#{System.unique_integer([:positive])}")
    end
  end
end
