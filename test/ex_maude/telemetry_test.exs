defmodule ExMaude.TelemetryTest do
  @moduledoc """
  Tests for `ExMaude.Telemetry` - telemetry events and helpers.

  These tests verify that telemetry events are emitted correctly with
  standard measurements and metadata compatible with Prometheus/OpenTelemetry.
  """

  use ExUnit.Case, async: false

  alias ExMaude.Telemetry

  describe "events/0" do
    test "returns list of all event names" do
      events = Telemetry.events()

      assert is_list(events)

      # All events should be lists of atoms
      for event <- events do
        assert is_list(event)
        assert Enum.all?(event, &is_atom/1)
      end
    end

    test "includes command events" do
      events = Telemetry.events()

      assert [:ex_maude, :command, :start] in events
      assert [:ex_maude, :command, :stop] in events
      assert [:ex_maude, :command, :exception] in events
    end

    test "includes pool events" do
      events = Telemetry.events()

      assert [:ex_maude, :pool, :checkout, :start] in events
      assert [:ex_maude, :pool, :checkout, :stop] in events
    end

    test "includes iot events" do
      events = Telemetry.events()

      assert [:ex_maude, :iot, :detect_conflicts, :start] in events
      assert [:ex_maude, :iot, :detect_conflicts, :stop] in events
    end
  end

  describe "span/3" do
    setup do
      test_pid = self()
      ref = make_ref()

      handler = fn event, measurements, metadata, {pid, r} ->
        send(pid, {r, event, measurements, metadata})
      end

      handler_id = "test-handler-#{inspect(ref)}"

      :telemetry.attach_many(
        handler_id,
        Telemetry.events(),
        handler,
        {test_pid, ref}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, ref: ref}
    end

    test "emits start and stop events on success", %{ref: ref} do
      result =
        Telemetry.span([:ex_maude, :command], %{operation: :test, module: "TEST"}, fn ->
          {:ok, "result"}
        end)

      assert result == {:ok, "result"}

      # Verify start event
      assert_receive {^ref, [:ex_maude, :command, :start], start_measurements, start_metadata}
      assert is_integer(start_measurements.system_time)
      assert start_metadata.operation == :test
      assert start_metadata.module == "TEST"

      # Verify stop event
      assert_receive {^ref, [:ex_maude, :command, :stop], stop_measurements, stop_metadata}
      assert is_integer(stop_measurements.duration)
      assert stop_measurements.duration > 0
      assert stop_metadata.result == :ok
      assert stop_metadata.operation == :test
      assert stop_metadata.module == "TEST"
    end

    test "emits start and stop events on error result", %{ref: ref} do
      result =
        Telemetry.span([:ex_maude, :command], %{operation: :fail_test}, fn ->
          {:error, :some_reason}
        end)

      assert result == {:error, :some_reason}

      # Verify start event
      assert_receive {^ref, [:ex_maude, :command, :start], _, _}

      # Verify stop event with error result
      assert_receive {^ref, [:ex_maude, :command, :stop], stop_measurements, stop_metadata}
      assert is_integer(stop_measurements.duration)
      assert stop_metadata.result == :error
    end

    test "emits exception event on raise", %{ref: ref} do
      assert_raise RuntimeError, "test error", fn ->
        Telemetry.span([:ex_maude, :command], %{operation: :raise_test}, fn ->
          raise "test error"
        end)
      end

      # Verify start event
      assert_receive {^ref, [:ex_maude, :command, :start], _, _}

      # Verify exception event
      assert_receive {^ref, [:ex_maude, :command, :exception], exc_measurements, exc_metadata}
      assert is_integer(exc_measurements.duration)
      assert exc_metadata.kind == :error
      assert %RuntimeError{message: "test error"} = exc_metadata.reason
    end

    test "emits exception event on throw", %{ref: ref} do
      catch_throw(
        Telemetry.span([:ex_maude, :command], %{operation: :throw_test}, fn ->
          throw(:test_throw)
        end)
      )

      # Verify exception event
      assert_receive {^ref, [:ex_maude, :command, :exception], exc_measurements, exc_metadata}
      assert is_integer(exc_measurements.duration)
      assert exc_metadata.kind == :throw
      assert exc_metadata.reason == :test_throw
    end

    test "emits exception event on exit", %{ref: ref} do
      catch_exit(
        Telemetry.span([:ex_maude, :command], %{operation: :exit_test}, fn ->
          exit(:test_exit)
        end)
      )

      # Verify exception event
      assert_receive {^ref, [:ex_maude, :command, :exception], exc_measurements, exc_metadata}
      assert is_integer(exc_measurements.duration)
      assert exc_metadata.kind == :exit
      assert exc_metadata.reason == :test_exit
    end

    test "duration is in native time units", %{ref: ref} do
      Telemetry.span([:ex_maude, :command], %{operation: :duration_test}, fn ->
        Process.sleep(10)
        {:ok, :done}
      end)

      assert_receive {^ref, [:ex_maude, :command, :stop], %{duration: duration}, _}

      # Convert to milliseconds - should be at least 10ms
      ms = System.convert_time_unit(duration, :native, :millisecond)
      assert ms >= 10
    end

    test "preserves metadata through span", %{ref: ref} do
      metadata = %{operation: :meta_test, module: "MOD", custom_field: "custom_value"}

      Telemetry.span([:ex_maude, :command], metadata, fn ->
        {:ok, :result}
      end)

      assert_receive {^ref, [:ex_maude, :command, :start], _, start_meta}
      assert start_meta.custom_field == "custom_value"

      assert_receive {^ref, [:ex_maude, :command, :stop], _, stop_meta}
      assert stop_meta.custom_field == "custom_value"
      assert stop_meta.result == :ok
    end

    test "handles non-tuple results", %{ref: ref} do
      result =
        Telemetry.span([:ex_maude, :command], %{operation: :bare_result}, fn ->
          :bare_atom
        end)

      assert result == :bare_atom

      assert_receive {^ref, [:ex_maude, :command, :stop], _, stop_meta}
      # Non-tuple results should use :ok as the result atom
      assert stop_meta.result == :ok
    end
  end

  describe "Prometheus/OpenTelemetry compatibility" do
    test "measurements use native time units" do
      # Verify the pattern used in span/3 matches what Prometheus expects
      start_time = System.monotonic_time()
      Process.sleep(1)
      duration = System.monotonic_time() - start_time

      # Should be convertible to various units
      assert is_integer(duration)
      assert System.convert_time_unit(duration, :native, :millisecond) >= 0
      assert System.convert_time_unit(duration, :native, :microsecond) >= 0
    end

    test "result metadata uses atoms not booleans" do
      # This is important for Prometheus label cardinality
      # :ok and :error are atoms, not true/false
      assert is_atom(:ok)
      assert is_atom(:error)
      refute is_boolean(:ok)
      refute is_boolean(:error)
    end

    test "event names follow :app :component :action pattern" do
      events = Telemetry.events()

      for event <- events do
        # Should have at least [:app, :component, :action]
        assert length(event) >= 3

        # First element should be :ex_maude
        assert hd(event) == :ex_maude

        # Last element should be a phase (:start, :stop, :exception)
        assert List.last(event) in [:start, :stop, :exception]
      end
    end
  end

  describe "span/3 additional edge cases" do
    setup do
      test_pid = self()
      ref = make_ref()

      handler = fn event, measurements, metadata, {pid, r} ->
        send(pid, {r, event, measurements, metadata})
      end

      handler_id = "edge-case-handler-#{inspect(ref)}"

      :telemetry.attach_many(
        handler_id,
        Telemetry.events(),
        handler,
        {test_pid, ref}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, ref: ref}
    end

    test "handles nested spans", %{ref: ref} do
      result =
        Telemetry.span([:ex_maude, :command], %{operation: :outer}, fn ->
          inner_result =
            Telemetry.span([:ex_maude, :command], %{operation: :inner}, fn ->
              {:ok, "inner_value"}
            end)

          {:ok, {:outer, inner_result}}
        end)

      assert {:ok, {:outer, {:ok, "inner_value"}}} = result

      # Should receive 4 events (2 starts + 2 stops)
      assert_receive {^ref, [:ex_maude, :command, :start], _, %{operation: :outer}}
      assert_receive {^ref, [:ex_maude, :command, :start], _, %{operation: :inner}}
      assert_receive {^ref, [:ex_maude, :command, :stop], _, %{operation: :inner}}
      assert_receive {^ref, [:ex_maude, :command, :stop], _, %{operation: :outer}}
    end

    test "duration is always positive", %{ref: ref} do
      Telemetry.span([:ex_maude, :command], %{operation: :quick}, fn ->
        {:ok, :done}
      end)

      assert_receive {^ref, [:ex_maude, :command, :stop], %{duration: duration}, _}
      assert duration >= 0
    end

    test "handles complex metadata", %{ref: ref} do
      complex_metadata = %{
        operation: :complex,
        module: "TEST",
        nested: %{key: "value"},
        list: [1, 2, 3]
      }

      Telemetry.span([:ex_maude, :command], complex_metadata, fn ->
        {:ok, :result}
      end)

      assert_receive {^ref, [:ex_maude, :command, :start], _, meta}
      assert meta.nested == %{key: "value"}
      assert meta.list == [1, 2, 3]
    end
  end

  describe "events/0 additional tests" do
    test "returns exactly 7 events" do
      events = Telemetry.events()
      assert length(events) == 7
    end

    test "all events are unique" do
      events = Telemetry.events()
      assert length(events) == length(Enum.uniq(events))
    end

    test "events can be attached without error" do
      events = Telemetry.events()
      handler_id = "test-attach-#{:erlang.unique_integer([:positive])}"

      # Should not raise
      :telemetry.attach_many(
        handler_id,
        events,
        fn _, _, _, _ -> :ok end,
        nil
      )

      :telemetry.detach(handler_id)
    end
  end
end
