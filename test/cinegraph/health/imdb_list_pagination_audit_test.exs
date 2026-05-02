defmodule Cinegraph.Health.ImdbListPaginationAuditTest do
  use Cinegraph.DataCase, async: true

  alias Cinegraph.Health.ImdbListPaginationAudit
  alias Cinegraph.Movies.MovieList
  alias Cinegraph.Repo

  describe "URL generation" do
    test "builds candidate list window URLs" do
      assert ImdbListPaginationAudit.default_starts() == [1, 76, 151, 226, 301, 376]

      assert ImdbListPaginationAudit.build_window_url("ls053182933", 76) ==
               "https://www.imdb.com/list/ls053182933/?sort=list_order,asc&start=76&mode=detail"
    end
  end

  describe "parser" do
    test "uses displayed ranks when present" do
      parsed =
        ImdbListPaginationAudit.parse_window_html(
          ipc_html([
            {76, "tt0073629", "The Rocky Horror Picture Show"},
            {77, "tt0091042", "Ferris Bueller's Day Off"}
          ]),
          76
        )

      assert parsed.parser_layout == "ipc"
      assert Enum.map(parsed.movies, & &1.rank) == [76, 77]
      assert Enum.all?(parsed.movies, &(&1.rank_source == "displayed"))
    end

    test "falls back to start plus item index when displayed ranks are absent" do
      parsed =
        ImdbListPaginationAudit.parse_window_html(
          fallback_html([
            {"tt0073629", "The Rocky Horror Picture Show"},
            {"tt0091042", "Ferris Bueller's Day Off"}
          ]),
          76
        )

      assert Enum.map(parsed.movies, & &1.rank) == [76, 77]
      assert Enum.all?(parsed.movies, &(&1.rank_source == "fallback"))
    end
  end

  describe "audit" do
    test "reports contiguous non-duplicative windows as safe to import" do
      result =
        audit_for_windows(%{
          1 =>
            ipc_html([
              {1, "tt0000001", "One"},
              {2, "tt0000002", "Two"}
            ]),
          3 =>
            ipc_html([
              {3, "tt0000003", "Three"},
              {4, "tt0000004", "Four"}
            ])
        })

      assert result.summary.total_unique_ids == 4
      assert result.summary.has_gaps == false
      assert result.summary.has_duplicates == false
      assert result.summary.recommended_page_size == 2
      assert result.summary.safe_to_import == true
      refute Map.has_key?(hd(result.windows), :_ids)
    end

    test "detects rank gaps between windows" do
      result =
        audit_for_windows(%{
          1 =>
            ipc_html([
              {1, "tt0000001", "One"},
              {2, "tt0000002", "Two"}
            ]),
          3 =>
            ipc_html([
              {500, "tt0000003", "Three"},
              {501, "tt0000004", "Four"}
            ])
        })

      assert result.summary.has_gaps == true
      assert result.summary.safe_to_import == false
      assert Enum.at(result.windows, 1).rank_gap_from_previous == 497
    end

    test "detects duplicate IDs across windows" do
      result =
        audit_for_windows(%{
          1 =>
            ipc_html([
              {1, "tt0000001", "One"},
              {2, "tt0000002", "Two"}
            ]),
          3 =>
            ipc_html([
              {3, "tt0000002", "Two Again"},
              {4, "tt0000004", "Four"}
            ])
        })

      assert result.summary.has_duplicates == true
      assert result.summary.safe_to_import == false
      assert Enum.at(result.windows, 1).duplicate_ids == ["tt0000002"]
    end

    test "detects duplicate IDs within a single rendered window" do
      result =
        audit_for_windows(%{
          1 =>
            ipc_html([
              {1, "tt0000001", "One"},
              {2, "tt0000001", "One Again"}
            ])
        })

      assert result.summary.total_unique_ids == 1
      assert result.summary.has_duplicates == true
      assert result.summary.safe_to_import == false
      assert hd(result.windows).duplicate_ids == ["tt0000001"]
    end

    test "marks zero-movie windows unsafe" do
      result =
        audit_for_windows(%{
          1 =>
            ipc_html([
              {1, "tt0000001", "One"},
              {2, "tt0000002", "Two"}
            ]),
          3 => "<html><body>No list items</body></html>"
        })

      assert Enum.at(result.windows, 1).movie_count == 0
      assert result.summary.safe_to_import == false
    end

    test "resolves --list through movie_lists config" do
      insert_movie_list!("cult_movies_400", "ls053182933")

      result =
        ImdbListPaginationAudit.audit(
          list: "cult_movies_400",
          starts: [1],
          fetcher:
            fetcher_for(%{
              1 => ipc_html([{1, "tt0000001", "One"}])
            })
        )

      assert result.list_key == "cult_movies_400"
      assert result.list_id == "ls053182933"
    end

    test "passes Crawlbase JS options through to fetcher and output" do
      parent = self()

      fetcher = fn _url, :imdb, opts ->
        send(parent, {:fetch_opts, opts})
        {:ok, ipc_html([{1, "tt0000001", "One"}]), %{adapter: "test"}}
      end

      result =
        ImdbListPaginationAudit.audit(
          list_id: "ls053182933",
          starts: [1],
          page_wait: 7_500,
          ajax_wait: false,
          scroll: true,
          scroll_interval: 800,
          fetcher: fetcher
        )

      assert_received {:fetch_opts,
                       [
                         mode: :javascript,
                         page_wait: 7_500,
                         ajax_wait: false,
                         scroll: true,
                         scroll_interval: 800
                       ]}

      assert hd(result.windows).crawlbase_options == %{
               page_wait: 7_500,
               ajax_wait: false,
               scroll: true,
               scroll_interval: 800
             }
    end
  end

  defp audit_for_windows(windows_by_start) do
    starts = windows_by_start |> Map.keys() |> Enum.sort()

    ImdbListPaginationAudit.audit(
      list_id: "ls053182933",
      starts: starts,
      fetcher: fetcher_for(windows_by_start)
    )
  end

  defp fetcher_for(windows_by_start) do
    fn url, :imdb, _opts ->
      start =
        url
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()
        |> Map.fetch!("start")
        |> String.to_integer()

      {:ok, Map.fetch!(windows_by_start, start)}
    end
  end

  defp ipc_html(items) do
    body =
      Enum.map_join(items, "\n", fn {rank, imdb_id, title} ->
        """
        <li class="ipc-metadata-list-summary-item">
          <h3 class="ipc-title__text">#{rank}. #{title}</h3>
          <a href="/title/#{imdb_id}/">#{title}</a>
        </li>
        """
      end)

    "<html><body><ul>#{body}</ul></body></html>"
  end

  defp fallback_html(items) do
    body =
      Enum.map_join(items, "\n", fn {imdb_id, title} ->
        """
        <div class="ipc-metadata-list-summary-item">
          <a href="/title/#{imdb_id}/">#{title}</a>
        </div>
        """
      end)

    "<html><body>#{body}</body></html>"
  end

  defp insert_movie_list!(source_key, list_id) do
    attrs = %{
      source_key: source_key,
      name: source_key,
      source_type: "imdb",
      source_url: "https://www.imdb.com/list/#{list_id}/",
      category: "curated",
      active: true,
      slug: source_key
    }

    %MovieList{}
    |> MovieList.changeset(attrs)
    |> Repo.insert!()
  end
end
