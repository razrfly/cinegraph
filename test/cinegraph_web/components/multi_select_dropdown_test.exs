defmodule CinegraphWeb.Components.MultiSelectDropdownTest do
  use CinegraphWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import CinegraphWeb.CoreComponents

  describe "multi_select_dropdown" do
    test "handles special characters in labels correctly" do
      options = [
        %{id: 1, name: "Bob's Movies"},
        %{id: 2, name: "<script>alert('xss')</script>"},
        %{id: 3, name: "你好世界 🚀"}
      ]
      
      selected = [1, 3]
      
      html = render_component(&multi_select_dropdown/1, %{
        id: "test-dropdown",
        options: options,
        selected: selected,
        label_field: :name,
        value_field: :id
      })
      
      # Parse the data attributes
      {:ok, document} = Floki.parse_document(html)
      
      data_selected_attr = Floki.attribute(document, "[data-selected]", "data-selected") |> List.first()
      data_options_attr = Floki.attribute(document, "[data-options]", "data-options") |> List.first()
      
      # Verify data-selected contains valid JSON
      {:ok, parsed_selected} = Jason.decode(data_selected_attr)
      assert parsed_selected == ["1", "3"]
      
      # Verify data-options contains valid JSON with properly escaped content
      {:ok, parsed_options} = Jason.decode(data_options_attr)
      
      assert length(parsed_options) == 3
      
      # Find the options by their values and verify labels are properly escaped
      bob_option = Enum.find(parsed_options, &(&1["value"] == "1"))
      script_option = Enum.find(parsed_options, &(&1["value"] == "2"))
      unicode_option = Enum.find(parsed_options, &(&1["value"] == "3"))
      
      assert bob_option["label"] == "Bob's Movies"
      assert script_option["label"] == "<script>alert('xss')</script>"
      assert unicode_option["label"] == "你好世界 🚀"
    end
    
    test "handles empty selected values" do
      options = [
        %{id: 1, name: "Test Movie"}
      ]
      
      html = render_component(&multi_select_dropdown/1, %{
        id: "test-dropdown",
        options: options,
        selected: [],
        label_field: :name,
        value_field: :id
      })
      
      {:ok, document} = Floki.parse_document(html)
      data_selected_attr = Floki.attribute(document, "[data-selected]", "data-selected") |> List.first()
      
      {:ok, parsed_selected} = Jason.decode(data_selected_attr)
      assert parsed_selected == []
    end
    
    test "handles empty options list" do
      html = render_component(&multi_select_dropdown/1, %{
        id: "test-dropdown",
        options: [],
        selected: [],
        label_field: :name,
        value_field: :id
      })
      
      {:ok, document} = Floki.parse_document(html)
      data_options_attr = Floki.attribute(document, "[data-options]", "data-options") |> List.first()
      
      {:ok, parsed_options} = Jason.decode(data_options_attr)
      assert parsed_options == []
    end
    
    test "handles options with only special characters" do
      options = [
        %{id: 1, name: "\"quotes\""},
        %{id: 2, name: "\\backslash"},
        %{id: 3, name: "\n\t\r"},
        %{id: 4, name: "🎬🍿🎭"}
      ]
      
      html = render_component(&multi_select_dropdown/1, %{
        id: "test-dropdown", 
        options: options,
        selected: [1, 4],
        label_field: :name,
        value_field: :id
      })
      
      {:ok, document} = Floki.parse_document(html)
      data_options_attr = Floki.attribute(document, "[data-options]", "data-options") |> List.first()
      data_selected_attr = Floki.attribute(document, "[data-selected]", "data-selected") |> List.first()
      
      # Should not raise errors when parsing
      {:ok, parsed_options} = Jason.decode(data_options_attr)
      {:ok, parsed_selected} = Jason.decode(data_selected_attr)
      
      assert length(parsed_options) == 4
      assert parsed_selected == ["1", "4"]
      
      # Verify special characters are properly escaped
      quotes_option = Enum.find(parsed_options, &(&1["value"] == "1"))
      backslash_option = Enum.find(parsed_options, &(&1["value"] == "2"))
      whitespace_option = Enum.find(parsed_options, &(&1["value"] == "3"))
      emoji_option = Enum.find(parsed_options, &(&1["value"] == "4"))
      
      assert quotes_option["label"] == "\"quotes\""
      assert backslash_option["label"] == "\\backslash"
      assert whitespace_option["label"] == "\n\t\r"
      assert emoji_option["label"] == "🎬🍿🎭"
    end
  end
end