defmodule Cinegraph.Workers.ConnectionMonitorWorkerTest do
  use Cinegraph.DataCase, async: true

  alias Cinegraph.Workers.ConnectionMonitorWorker

  test "perform/1 returns {:ok, snapshot} and doesn't raise" do
    assert {:ok, snapshot} = ConnectionMonitorWorker.perform(%Oban.Job{})
    assert snapshot.status in [:ok, :warn, :crit]
    assert is_integer(snapshot.total_backends)
  end
end
