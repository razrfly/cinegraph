defmodule Cinegraph.Health.ImdbEventInspectorTest do
  use ExUnit.Case, async: true

  alias Cinegraph.Health.ImdbEventInspector

  describe "parse_inspection_html/3" do
    test "populated __NEXT_DATA__ with editions returns :ok and lists years" do
      html =
        next_data_html(%{
          "props" => %{
            "pageProps" => %{
              "edition" => %{"event" => %{"name" => "Cannes Film Festival"}},
              "historyEventEditions" => [
                %{"year" => 2026},
                %{"year" => 2025},
                %{"year" => 2024}
              ]
            }
          }
        })

      r = ImdbEventInspector.parse_inspection_html(html, "ev0000147", "https://example.test")

      assert r.parser_status == :ok
      assert r.has_next_data == true
      assert r.editions_count == 3
      assert r.years_with_data.count == 3
      assert r.years_with_data.sample == [2026, 2025, 2024]
      assert r.event_name == "Cannes Film Festival"
      assert r.suggested_label == :ok
      assert r.fetch_status == :ok
      assert r.bytes == byte_size(html)
    end

    test "empty historyEventEditions array → :no_editions / :source_unavailable" do
      html =
        next_data_html(%{
          "props" => %{
            "pageProps" => %{
              "edition" => %{"event" => %{"name" => "Some Event"}},
              "historyEventEditions" => []
            }
          }
        })

      r = ImdbEventInspector.parse_inspection_html(html, "ev0000400", "https://example.test")

      assert r.parser_status == :no_editions
      assert r.has_next_data == true
      assert r.editions_count == 0
      assert r.years_with_data.count == 0
      assert r.suggested_label == :source_unavailable
      assert r.event_name == "Some Event"
    end

    test "editions present but no `year` fields → :editions_parser_breakage / :parser_breakage" do
      html =
        next_data_html(%{
          "props" => %{
            "pageProps" => %{
              "historyEventEditions" => [
                %{"some_other_field" => "x"},
                %{"some_other_field" => "y"}
              ]
            }
          }
        })

      r = ImdbEventInspector.parse_inspection_html(html, "ev0000999", "https://example.test")

      assert r.parser_status == :editions_parser_breakage
      assert r.editions_count == 2
      assert r.years_with_data.count == 0
      assert r.suggested_label == :parser_breakage
    end

    test "missing __NEXT_DATA__ tag with normal-size body → :no_next_data / :parser_breakage" do
      # Pad to >=5KB so the size-heuristic doesn't kick in
      padding = String.duplicate("<p>filler</p>", 1000)
      html = "<html><body>#{padding}Page without next-data</body></html>"

      r = ImdbEventInspector.parse_inspection_html(html, "ev0000484", "https://example.test")

      assert r.parser_status == :no_next_data
      assert r.has_next_data == false
      assert r.suggested_label == :parser_breakage
    end

    test "403 Forbidden body without __NEXT_DATA__ → :bad_event_id" do
      html =
        "<html><head><title>403 Forbidden</title></head><body><h1>403 Forbidden</h1></body></html>"

      r = ImdbEventInspector.parse_inspection_html(html, "ev0002561", "https://example.test")

      assert r.parser_status == :no_next_data
      assert r.suggested_label == :bad_event_id
    end

    test "tiny body without __NEXT_DATA__ → :bad_event_id (size heuristic)" do
      html = "<html><body>tiny</body></html>"

      r = ImdbEventInspector.parse_inspection_html(html, "ev0000xxx", "https://example.test")

      assert r.parser_status == :no_next_data
      assert r.suggested_label == :bad_event_id
    end

    test "malformed JSON inside __NEXT_DATA__ → :json_failed" do
      html = ~s|<script id="__NEXT_DATA__" type="application/json">{not json}</script>|

      r = ImdbEventInspector.parse_inspection_html(html, "ev0000666", "https://example.test")

      assert r.parser_status == :json_failed
      assert r.has_next_data == true
      assert r.suggested_label == :parser_breakage
    end

    test "raw_excerpt is capped at 200 bytes" do
      html =
        next_data_html(%{
          "props" => %{
            "pageProps" => %{"historyEventEditions" => []}
          }
        })

      r = ImdbEventInspector.parse_inspection_html(html, "ev0000xxx", "https://example.test")
      assert byte_size(r.raw_excerpt) <= 200
    end
  end

  defp next_data_html(data) do
    json = Jason.encode!(data)

    ~s|<html><body><script id="__NEXT_DATA__" type="application/json">#{json}</script></body></html>|
  end
end
