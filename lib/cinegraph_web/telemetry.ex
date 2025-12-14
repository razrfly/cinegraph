defmodule CinegraphWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Primary Database Metrics
      summary("cinegraph.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("cinegraph.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("cinegraph.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("cinegraph.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("cinegraph.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # Replica Database Metrics
      summary("cinegraph.repo.replica.query.total_time",
        unit: {:native, :millisecond},
        description: "Total time for replica queries"
      ),
      summary("cinegraph.repo.replica.query.decode_time",
        unit: {:native, :millisecond},
        description: "Time spent decoding replica data"
      ),
      summary("cinegraph.repo.replica.query.query_time",
        unit: {:native, :millisecond},
        description: "Time spent executing replica queries"
      ),
      summary("cinegraph.repo.replica.query.queue_time",
        unit: {:native, :millisecond},
        description: "Time spent waiting for replica connection"
      ),
      summary("cinegraph.repo.replica.query.idle_time",
        unit: {:native, :millisecond},
        description: "Replica connection idle time before checkout"
      ),

      # Database Distribution Metrics (counters for read distribution tracking)
      counter("cinegraph.repo.query.count",
        description: "Number of primary database queries"
      ),
      counter("cinegraph.repo.replica.query.count",
        description: "Number of replica database queries"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # Database Pool Metrics (periodic)
      last_value("cinegraph.repo.pool.size",
        description: "Primary pool size"
      ),
      last_value("cinegraph.repo.pool.available",
        description: "Primary pool available connections"
      ),
      last_value("cinegraph.repo.replica.pool.size",
        description: "Replica pool size"
      ),
      last_value("cinegraph.repo.replica.pool.available",
        description: "Replica pool available connections"
      )
    ]
  end

  defp periodic_measurements do
    [
      # Database pool stats
      {Cinegraph.Repo.Metrics, :measure_pool_stats, []}
    ]
  end
end
