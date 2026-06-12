defmodule Cinegraph.Maintenance.ImportListEventsTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.ListEvents.ListMembershipEvent
  alias Cinegraph.Maintenance.ImportListEvents
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Repo
  alias Cinegraph.Scrapers.FestivalHttpStub

  setup do
    FestivalHttpStub.reset!()
    prev = Application.get_env(:cinegraph, :movies_1001_edition_urls)

    Application.put_env(:cinegraph, :movies_1001_edition_urls, [
      {"2003", "https://example.test/1001-ed-2003"},
      {"2006", "https://example.test/1001-ed-2006"}
    ])

    on_exit(fn -> Application.put_env(:cinegraph, :movies_1001_edition_urls, prev) end)
    :ok
  end

  defp insert_movie(attrs) do
    %Movie{}
    |> Movie.changeset(Map.put_new(attrs, :tmdb_id, System.unique_integer([:positive])))
    |> Repo.insert!()
  end

  defp nfr_wiki_html do
    """
    <html><body><table class="wikitable">
      <tr><th>Film</th><th>Type</th><th>Year released</th><th>Year inducted</th></tr>
      <tr><td>Casablanca</td><td>Narrative feature</td><td>1942</td><td>1989</td></tr>
      <tr><td>Some Obscure Short</td><td>Short</td><td>1910</td><td>1995</td></tr>
    </table></body></html>
    """
  end

  defp ed_html(films) do
    items = Enum.map_join(films, "\n", fn {t, y} -> "<li>#{t} (#{y})</li>" end)
    "<html><body><ul>#{items}</ul></body></html>"
  end

  defp stub_all do
    FestivalHttpStub.set_response("National_Film_Registry", {:ok, nfr_wiki_html()})
    FestivalHttpStub.set_response("loc.gov", {:error, :forbidden})

    FestivalHttpStub.set_response(
      "/1001-ed-2003",
      {:ok, ed_html([{"Casablanca", 1942}, {"Gone Soon", 1950}])}
    )

    FestivalHttpStub.set_response("/1001-ed-2006", {:ok, ed_html([{"Casablanca", 1942}])})
  end

  describe "run/1 over all sources" do
    test "imports matched and pending events, never dropping unmatched rows" do
      # Casablanca exists → matches; the obscure short and "Gone Soon" do not.
      insert_movie(%{title: "Casablanca", release_date: ~D[1942-11-26]})
      stub_all()

      assert {:ok, %{sources: sources, dry_run: false}} = ImportListEvents.run(all: true)

      nfr = Enum.find(sources, &(&1.source_key == "national_film_registry"))
      assert nfr.found == 2
      assert nfr.matched == 1
      assert nfr.pending == 1

      m1001 = Enum.find(sources, &(&1.source_key == "1001_movies"))
      # 2003 baseline: Casablanca + Gone Soon added; 2006: Gone Soon removed.
      assert m1001.found == 3

      # Pending rows are persisted, not dropped.
      pending_count =
        Repo.aggregate(from(e in ListMembershipEvent, where: e.match_state == "pending"), :count)

      assert pending_count >= 2
    end

    test "is idempotent across runs" do
      insert_movie(%{title: "Casablanca", release_date: ~D[1942-11-26]})
      stub_all()

      {:ok, _} = ImportListEvents.run(all: true)
      count1 = Repo.aggregate(ListMembershipEvent, :count)

      stub_all()
      {:ok, _} = ImportListEvents.run(all: true)
      count2 = Repo.aggregate(ListMembershipEvent, :count)

      assert count1 == count2
    end

    test "dry_run scrapes and matches but writes nothing" do
      insert_movie(%{title: "Casablanca", release_date: ~D[1942-11-26]})
      stub_all()

      assert {:ok, %{dry_run: true, sources: sources}} =
               ImportListEvents.run(all: true, dry_run: true)

      assert Enum.all?(sources, &(&1.upserted == 0))
      assert Repo.aggregate(ListMembershipEvent, :count) == 0
    end

    test "single source selector" do
      insert_movie(%{title: "Casablanca", release_date: ~D[1942-11-26]})
      stub_all()

      assert {:ok, %{sources: [nfr]}} = ImportListEvents.run(source: "national_film_registry")
      assert nfr.source_key == "national_film_registry"
    end

    test "requires exactly one selector" do
      assert_raise ArgumentError, fn -> ImportListEvents.run([]) end
      assert_raise ArgumentError, fn -> ImportListEvents.run(source: "x", all: true) end
    end
  end

  describe "rematch_pending" do
    test "promotes pending rows that now resolve" do
      stub_all()
      {:ok, _} = ImportListEvents.run(all: true)

      # Now create the movie that was previously unmatched, then re-match.
      insert_movie(%{title: "Gone Soon", release_date: ~D[1950-01-01]})

      assert {:ok, %{rematch_pending: true, promoted: promoted}} =
               ImportListEvents.run(rematch_pending: true)

      assert promoted >= 1
    end
  end
end
