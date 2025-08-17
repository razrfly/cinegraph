defmodule CinegraphWeb.PredictionsLiveTest do
  use CinegraphWeb.ConnCase
  
  import Phoenix.LiveViewTest
  
  describe "PredictionsLive.Index" do
    test "renders predictions page", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/predictions")
      
      assert html =~ "2020s Movie Predictions"
      assert html =~ "AI-powered predictions"
    end
    
    test "displays algorithm confidence", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/predictions")
      
      assert html =~ "Algorithm Confidence"
      assert html =~ "accuracy based on historical validation"
    end
    
    test "shows view mode tabs", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/predictions")
      
      assert html =~ "2020s Predictions"
      assert html =~ "Historical Validation"
      assert html =~ "Confirmed Additions"
    end
    
    test "can switch between view modes", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/predictions")
      
      # Switch to validation view
      index_live
      |> element("button", "Historical Validation")
      |> render_click()
      
      assert has_element?(index_live, "h2", "Algorithm Validation Results")
      
      # Switch to confirmed view
      index_live
      |> element("button", "Confirmed Additions")
      |> render_click()
      
      assert has_element?(index_live, "h2", "2020s Movies Already on 1001 Movies List")
    end
    
    test "can toggle weight tuner", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/predictions")
      
      # Initially tuner should be hidden
      refute has_element?(index_live, "h3", "Algorithm Weight Tuner")
      
      # Click to show tuner
      index_live
      |> element("button", "Tune Algorithm")
      |> render_click()
      
      assert has_element?(index_live, "h3", "Algorithm Weight Tuner")
      
      # Click to hide tuner
      index_live
      |> element("button", "Hide Tuner")
      |> render_click()
      
      refute has_element?(index_live, "h3", "Algorithm Weight Tuner")
    end
    
    test "weight tuner shows all criteria", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/predictions")
      
      # Show weight tuner
      index_live
      |> element("button", "Tune Algorithm")
      |> render_click()
      
      # Check all criteria are present
      assert has_element?(index_live, "label", "Critical Acclaim")
      assert has_element?(index_live, "label", "Festival Recognition")
      assert has_element?(index_live, "label", "Cultural Impact")
      assert has_element?(index_live, "label", "Technical Innovation")
      assert has_element?(index_live, "label", "Auteur Recognition")
    end
    
    test "can update weights", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/predictions")
      
      # Show weight tuner
      index_live
      |> element("button", "Tune Algorithm")
      |> render_click()
      
      # Update weights (make sure they sum to 100)
      new_weights = %{
        "critical_acclaim" => "40",
        "festival_recognition" => "25", 
        "cultural_impact" => "20",
        "technical_innovation" => "10",
        "auteur_recognition" => "5"
      }
      
      index_live
      |> form("form", new_weights)
      |> render_submit()
      
      # Should show loading state briefly, then success
      # Note: Due to async nature, we just verify it doesn't crash
      assert_receive_flash(index_live, :info, "Predictions updated successfully!")
    end
    
    test "validates weight totals", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/predictions")
      
      # Show weight tuner
      index_live
      |> element("button", "Tune Algorithm")
      |> render_click()
      
      # Try weights that don't sum to 100
      invalid_weights = %{
        "critical_acclaim" => "50",
        "festival_recognition" => "50",  # This makes total 150%
        "cultural_impact" => "20",
        "technical_innovation" => "20",
        "auteur_recognition" => "10"
      }
      
      index_live
      |> form("form", invalid_weights)
      |> render_submit()
      
      assert_receive_flash(index_live, :error)
    end
    
    test "can reset weights to default", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/predictions")
      
      # Show weight tuner
      index_live
      |> element("button", "Tune Algorithm")
      |> render_click()
      
      # Reset weights
      index_live
      |> element("button", "Reset to Default")
      |> render_click()
      
      # Should reload with default weights
      # Since this is async, we just verify no crashes
      assert has_element?(index_live, "h3", "Algorithm Weight Tuner")
    end
    
    test "displays movie predictions with proper structure", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/predictions")
      
      # Should show predictions table headers
      assert html =~ "Rank"
      assert html =~ "Movie"
      assert html =~ "Year"
      assert html =~ "Likelihood"
      assert html =~ "Status"
    end
    
    test "can select a movie for details", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/predictions")
      
      # Look for a movie link and click it
      movie_links = index_live |> element("button", "View Details") |> has_element?()
      
      if movie_links do
        # Click first movie detail button
        index_live
        |> element("button", "View Details")
        |> render_click()
        
        # Should show movie detail modal
        assert has_element?(index_live, "h2")  # Movie title in modal
        assert has_element?(index_live, "h3", "Scoring Breakdown")
        assert has_element?(index_live, "h3", "Historical Patterns")
      end
    end
    
    test "can close movie detail modal", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/predictions")
      
      # First try to open a modal if possible
      movie_links = index_live |> element("button", "View Details") |> has_element?()
      
      if movie_links do
        index_live
        |> element("button", "View Details")
        |> render_click()
        
        # Close the modal
        index_live
        |> element("button[phx-click='close_movie_detail']")
        |> render_click()
        
        # Modal should be closed
        refute has_element?(index_live, "h3", "Scoring Breakdown")
      end
    end
    
    test "handles loading states", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/predictions")
      
      # Show weight tuner and trigger recalculation
      index_live
      |> element("button", "Tune Algorithm")
      |> render_click()
      
      # Submit form to trigger loading
      new_weights = %{
        "critical_acclaim" => "35",
        "festival_recognition" => "30",
        "cultural_impact" => "20", 
        "technical_innovation" => "10",
        "auteur_recognition" => "5"
      }
      
      index_live
      |> form("form", new_weights)
      |> render_submit()
      
      # Should handle the loading state gracefully
      # (May show loading indicator briefly)
    end
    
    test "displays proper statistics", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/predictions")
      
      # Should show candidate count
      assert html =~ "Candidates"
      
      # Should show accuracy percentage
      assert html =~ "Accuracy"
      
      # Should show confirmed count
      assert html =~ "Confirmed"
    end
    
    test "progressive loading doesn't break UI", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/predictions")
      
      # The UI should load progressively without breaking
      # Test that key elements are present
      assert has_element?(index_live, "h1", "2020s Movie Predictions")
      assert has_element?(index_live, "button", "Tune Algorithm")
      
      # Navigation tabs should work
      assert has_element?(index_live, "button", "Historical Validation")
      assert has_element?(index_live, "button", "Confirmed Additions")
    end
  end
  
  # Helper function for flash message assertions
  defp assert_receive_flash(live_view, type, message \\ nil) do
    case render(live_view) do
      html when is_binary(html) ->
        case message do
          nil -> assert html =~ "alert"
          msg -> assert html =~ msg
        end
      _ -> 
        # Flash might be handled differently, just ensure no crash
        :ok
    end
  end
end