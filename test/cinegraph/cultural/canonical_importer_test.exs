defmodule Cinegraph.Cultural.CanonicalImporterTest do
  use Cinegraph.DataCase, async: false
  use Oban.Testing, repo: Cinegraph.Repo

  alias Cinegraph.Cultural.CanonicalImporter
  alias Cinegraph.Workers.CanonicalImportWorker
  alias Cinegraph.Workers.TMDbDetailsWorker
  alias Cinegraph.Scrapers.FestivalHttpStub
  alias Cinegraph.Movies.{MovieList, MovieLists}

  setup do
    FestivalHttpStub.reset!()
    :ok
  end

  describe "import_canonical_list/5 (embedded JSON path)" do
    test "parses the embedded JSON, reports the expected count, and queues new movies" do
      edges = for i <- 1..5, do: edge(i, "tt#{2_000_000 + i}", "Imported Movie #{i}")
      FestivalHttpStub.set_response("/list/ls90000001/", {:ok, next_data_html(edges)})

      result =
        CanonicalImporter.import_canonical_list(
          "ls90000001",
          "test_importer_list",
          "Test Importer List",
          [create_movies: true],
          %{}
        )

      assert result.total_movies == 5
      # expected_count comes from the JSON `total` field (count validation)
      assert result.expected_count == 5
      # all are new (fake imdb_ids) so they are queued for TMDb creation
      assert result.movies_queued == 5
      assert_enqueued(worker: TMDbDetailsWorker)
    end

    test "returns an error map when the fetch yields no movies" do
      FestivalHttpStub.set_response(
        "/list/ls90000002/",
        {:ok, "<html><body>nothing</body></html>"}
      )

      result =
        CanonicalImporter.import_canonical_list(
          "ls90000002",
          "test_empty_list",
          "Empty List",
          [create_movies: true],
          %{}
        )

      assert result.total_movies == 0
      assert Map.has_key?(result, :error)
    end
  end

  describe "CanonicalImportWorker (single path + status lifecycle)" do
    test "imports via the worker and finalizes movie_lists import status" do
      list =
        %MovieList{}
        |> MovieList.changeset(%{
          source_key: "worker_list",
          source_id: "ls90000003",
          name: "Worker List",
          source_type: "imdb",
          source_url: "https://www.imdb.com/list/ls90000003/",
          category: "curated",
          active: true,
          metadata: %{}
        })
        |> Repo.insert!()

      edges = for i <- 1..3, do: edge(i, "tt#{3_000_000 + i}", "Worker Movie #{i}")
      FestivalHttpStub.set_response("/list/ls90000003/", {:ok, next_data_html(edges)})

      Phoenix.PubSub.subscribe(Cinegraph.PubSub, "import_progress")

      assert :ok =
               perform_job(CanonicalImportWorker, %{
                 "action" => "import_canonical_list",
                 "list_key" => "worker_list"
               })

      # Broadcasts the dashboard listens for (scoped to this list_key to stay deterministic)
      assert_received {:canonical_progress, %{status: :started, list_key: "worker_list"}}

      assert_received {:canonical_progress,
                       %{status: :completed, list_key: "worker_list"} = completed}

      assert completed.expected_movies == 3
      # All 3 items are new → queued (0 persisted yet). Status must reflect items PROCESSED,
      # so a fully-queued import is "success", not "failed".
      assert completed.import_status == "success"

      # movie_lists import-status lifecycle was finalized (ported from the old completion worker)
      reloaded = Repo.get!(MovieList, list.id)
      assert reloaded.last_import_status == "success"
      assert reloaded.total_imports == 1
      refute is_nil(reloaded.last_import_at)
      assert reloaded.metadata["expected_movie_count"] == 3
    end
  end

  # --- helpers ---

  defp edge(position, imdb_id, original_title) do
    %{
      "node" => %{"absolutePosition" => position},
      "listItem" => %{
        "id" => imdb_id,
        "originalTitleText" => %{"text" => original_title},
        "titleText" => %{"text" => original_title},
        "releaseYear" => %{"year" => 2000 + position}
      }
    }
  end

  defp next_data_html(edges) do
    data = %{
      "props" => %{
        "pageProps" => %{
          "mainColumnData" => %{
            "list" => %{
              "titleListItemSearch" => %{
                "total" => length(edges),
                "pageInfo" => %{"hasNextPage" => false, "endCursor" => "CURSOR"},
                "edges" => edges
              }
            }
          }
        }
      }
    }

    """
    <html><body>
    <script id="__NEXT_DATA__" type="application/json">#{Jason.encode!(data)}</script>
    </body></html>
    """
  end
end
