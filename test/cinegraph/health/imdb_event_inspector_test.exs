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

    test "editions present but no `year` fields → :no_editions / :parser_breakage" do
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

      assert r.parser_status == :no_editions
      assert r.editions_count == 2
      assert r.years_with_data.count == 0
      assert r.suggested_label == :parser_breakage
    end

    test "missing __NEXT_DATA__ tag → :no_next_data / :parser_breakage" do
      html = "<html><body>Page without next-data</body></html>"

      r = ImdbEventInspector.parse_inspection_html(html, "ev0000484", "https://example.test")

      assert r.parser_status == :no_next_data
      assert r.has_next_data == false
      assert r.suggested_label == :parser_breakage
      assert r.raw_excerpt == String.slice(html, 0, 200)
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
