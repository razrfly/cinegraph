defmodule CinegraphWeb.HealthControllerTest do
  use CinegraphWeb.ConnCase

  describe "GET /health" do
    test "returns ok status", %{conn: conn} do
      conn = get(conn, ~p"/health")
      response = json_response(conn, 200)

      assert response["status"] == "ok"
      assert response["service"] == "cinegraph"
      assert response["timestamp"]
    end
  end

  describe "GET /health/db" do
    test "returns database health status", %{conn: conn} do
      conn = get(conn, ~p"/health/db")
      # Should return 200 if primary is healthy, 503 if not
      response = json_response(conn, conn.status)

      assert response["databases"]["primary"]
      assert response["databases"]["replica"]
      assert response["timestamp"]
    end

    test "includes latency for healthy connections", %{conn: conn} do
      conn = get(conn, ~p"/health/db")
      response = json_response(conn, conn.status)

      # In test environment, both repos point to same database
      if response["databases"]["primary"]["status"] == "healthy" do
        assert is_number(response["databases"]["primary"]["latency_ms"])
      end
    end
  end

  describe "GET /health/metrics" do
    test "returns metrics with query distribution", %{conn: conn} do
      conn = get(conn, ~p"/health/metrics")
      response = json_response(conn, 200)

      assert response["status"] == "ok"
      assert response["databases"]
      assert response["query_distribution"]
      assert is_number(response["query_distribution"]["primary_queries"])
      assert is_number(response["query_distribution"]["replica_queries"])
      assert is_number(response["query_distribution"]["total_queries"])
      assert response["query_distribution"]["quality"]
      assert response["timestamp"]
    end

    test "includes distribution quality indicator", %{conn: conn} do
      conn = get(conn, ~p"/health/metrics")
      response = json_response(conn, 200)

      # Quality should be one of the known values
      quality = response["query_distribution"]["quality"]
      assert quality in ["insufficient_data", "needs_attention", "improving", "good", "optimal"]
    end
  end

  describe "POST /health/metrics/reset" do
    test "resets query counters", %{conn: conn} do
      conn = post(conn, ~p"/health/metrics/reset")
      response = json_response(conn, 200)

      assert response["status"] == "ok"
      assert response["message"] == "Counters reset successfully"
      assert response["timestamp"]
    end
  end
end
