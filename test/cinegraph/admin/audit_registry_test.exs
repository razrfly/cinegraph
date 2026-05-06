defmodule Cinegraph.Admin.AuditRegistryTest do
  use Cinegraph.DataCase, async: true

  alias Cinegraph.Admin.AuditRegistry

  describe "registry shape" do
    test "every entry has all required keys with correct types" do
      for entry <- AuditRegistry.all() do
        assert is_atom(entry.id), "id must be atom: #{inspect(entry)}"
        assert is_binary(entry.label), "label must be string: #{inspect(entry.id)}"

        assert is_atom(entry.module) and Code.ensure_loaded?(entry.module),
               "module not loadable: #{inspect(entry.module)} for id #{inspect(entry.id)}"

        assert is_atom(entry.audit_fun)
        assert entry.arity in [:zero, :opts, :required]
        assert is_list(entry.args)
        assert is_binary(entry.description) and entry.description != ""
        assert entry.speed in [:fast, :slow]
        assert is_atom(entry.destination)
      end
    end

    test "ids are unique" do
      ids = AuditRegistry.all() |> Enum.map(& &1.id)
      assert length(ids) == length(Enum.uniq(ids))
    end

    test "audit function exists at expected arity for each entry" do
      for entry <- AuditRegistry.all() do
        expected_arity =
          case entry.arity do
            :zero -> 0
            :opts -> 1
            :required -> 2
          end

        exported =
          entry.module.__info__(:functions)
          |> Enum.any?(fn {name, arity} ->
            name == entry.audit_fun and arity == expected_arity
          end)

        assert exported,
               "#{inspect(entry.module)}.#{entry.audit_fun}/#{expected_arity} not exported (id=#{entry.id})"
      end
    end
  end

  describe "lookups" do
    test "by_id/1 returns nil for unknown id" do
      assert AuditRegistry.by_id(:no_such_id_anywhere) == nil
    end

    test "by_id/1 returns the matching entry" do
      assert %{id: :availability, module: Cinegraph.Health.AvailabilityAudit} =
               AuditRegistry.by_id(:availability)
    end

    test "by_speed/1 partitions correctly" do
      fast = AuditRegistry.by_speed(:fast)
      slow = AuditRegistry.by_speed(:slow)

      assert Enum.all?(fast, &(&1.speed == :fast))
      assert Enum.all?(slow, &(&1.speed == :slow))
      assert length(fast) + length(slow) == length(AuditRegistry.all())
    end

    test "by_destination/1 filters by domain" do
      imports = AuditRegistry.by_destination(:imports)
      assert Enum.all?(imports, &(&1.destination == :imports))
      assert Enum.any?(imports, &(&1.id == :canonical_lists))
    end
  end

  describe "run/2" do
    test "returns {:error, :unknown_audit} for missing id" do
      assert {:error, :unknown_audit} = AuditRegistry.run(:no_such_audit)
    end

    test "returns {:error, :missing_required_arg} for :required-arity without arg" do
      assert {:error, :missing_required_arg} = AuditRegistry.run(:imdb_event_id)
    end

    @tag :integration
    test "fast audits return {:ok, map} or a clean {:error, _}" do
      # Run all fast audits and accept either:
      #  - {:ok, map}: clean success — most audits
      #  - {:error, {:exception, msg}}: expected when an audit needs runtime
      #    args (e.g. :queue_failures requires :queue or :worker)
      # The point is that AuditRegistry.run/2 never lets an audit crash the
      # caller. UI surface enforces required args at the form layer.
      for entry <- AuditRegistry.by_speed(:fast) do
        case AuditRegistry.run(entry.id) do
          {:ok, result} ->
            assert is_map(result),
                   "expected #{entry.id} audit to return a map, got: #{inspect(result)}"

          {:error, {:exception, _msg}} ->
            :ok

          {:error, reason} ->
            flunk("fast audit #{entry.id} failed unexpectedly: #{inspect(reason)}")
        end
      end
    end
  end
end
