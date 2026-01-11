defmodule ExMaude.Telemetry do
  @moduledoc """
  Telemetry events for ExMaude.

  ExMaude uses the standard `:telemetry` library to emit events that can be
  consumed by monitoring tools, custom handlers, or exported to Prometheus,
  OpenTelemetry, and other observability platforms.

  ## Event Conventions

  All events follow standard conventions compatible with `telemetry_metrics`,
  Prometheus exporters, and OpenTelemetry:

  - **Measurements** are always numeric values (durations in native time units)
  - **Metadata** contains atoms for tags/labels (`:ok` or `:error`, not booleans)
  - **Event names** follow `[:app, :component, :action, :phase]` pattern

  ## Events

  ### Command Events

  Emitted for all Maude operations (reduce, rewrite, search, execute, etc.)

  `[:ex_maude, :command, :start]`
  - Measurements: `%{system_time: integer}`
  - Metadata: `%{operation: atom, module: String.t}`

  `[:ex_maude, :command, :stop]`
  - Measurements: `%{duration: integer}` (native time units)
  - Metadata: `%{operation: atom, module: String.t, result: :ok | :error}`

  `[:ex_maude, :command, :exception]`
  - Measurements: `%{duration: integer}`
  - Metadata: `%{operation: atom, module: String.t, kind: atom, reason: term}`

  ### Pool Events

  Emitted for worker pool checkout operations.

  `[:ex_maude, :pool, :checkout, :start]`
  - Measurements: `%{system_time: integer}`
  - Metadata: `%{}`

  `[:ex_maude, :pool, :checkout, :stop]`
  - Measurements: `%{duration: integer}`
  - Metadata: `%{result: :ok | :error}`

  ### IoT Events

  Emitted for IoT conflict detection operations.

  `[:ex_maude, :iot, :detect_conflicts, :start]`
  - Measurements: `%{system_time: integer, rule_count: integer}`
  - Metadata: `%{}`

  `[:ex_maude, :iot, :detect_conflicts, :stop]`
  - Measurements: `%{duration: integer, conflict_count: integer}`
  - Metadata: `%{result: :ok | :error}`

  ## Attaching Handlers

  Attach a handler to receive telemetry events:

      :telemetry.attach(
        "my-app-ex-maude-handler",
        [:ex_maude, :command, :stop],
        fn event, measurements, metadata, config ->
          Logger.info("ExMaude command completed",
            operation: metadata.operation,
            duration_ms: System.convert_time_unit(measurements.duration, :native, :millisecond),
            result: metadata.result
          )
        end,
        nil
      )

  Or attach to multiple events:

      :telemetry.attach_many(
        "my-app-ex-maude-handlers",
        ExMaude.Telemetry.events(),
        &MyApp.Telemetry.handle_event/4,
        nil
      )

  ## Prometheus Integration

  Using `telemetry_metrics` in your consuming application:

      defp metrics do
        [
          counter("ex_maude.command.stop.count",
            tags: [:operation, :result],
            description: "Total Maude commands executed"
          ),
          distribution("ex_maude.command.stop.duration",
            unit: {:native, :millisecond},
            tags: [:operation, :result],
            description: "Maude command execution time"
          ),
          counter("ex_maude.pool.checkout.stop.count",
            tags: [:result],
            description: "Pool checkout operations"
          ),
          distribution("ex_maude.pool.checkout.stop.duration",
            unit: {:native, :millisecond},
            tags: [:result],
            description: "Pool checkout time"
          ),
          counter("ex_maude.iot.detect_conflicts.stop.count",
            tags: [:result],
            description: "IoT conflict detections"
          ),
          last_value("ex_maude.iot.detect_conflicts.stop.conflict_count",
            description: "Number of conflicts detected"
          )
        ]
      end

  ## OpenTelemetry Integration

  Using `opentelemetry_telemetry` in your consuming application:

      OpentelemetryTelemetry.attach_default_handlers()

  ## Converting Duration

  Durations are in native time units. Convert for display:

      duration_ms = System.convert_time_unit(duration, :native, :millisecond)
      duration_us = System.convert_time_unit(duration, :native, :microsecond)
  """

  @doc """
  Returns a list of all telemetry events emitted by ExMaude.

  Useful for attaching handlers to all events at once:

      :telemetry.attach_many(
        "my-handler",
        ExMaude.Telemetry.events(),
        &handle_event/4,
        nil
      )

  ## Examples

      iex> events = ExMaude.Telemetry.events()
      ...> [:ex_maude, :command, :stop] in events
      true
  """
  @dialyzer {:nowarn_function, events: 0}
  @spec events() :: [nonempty_list(atom())]
  def events do
    [
      [:ex_maude, :command, :start],
      [:ex_maude, :command, :stop],
      [:ex_maude, :command, :exception],
      [:ex_maude, :pool, :checkout, :start],
      [:ex_maude, :pool, :checkout, :stop],
      [:ex_maude, :iot, :detect_conflicts, :start],
      [:ex_maude, :iot, :detect_conflicts, :stop]
    ]
  end

  @doc """
  Executes a function and emits start/stop/exception telemetry events.

  This is used internally by ExMaude modules to instrument operations.
  The function should return a tuple where the first element is `:ok` or `:error`.

  ## Parameters

  - `event` - The event prefix (e.g., `[:ex_maude, :command]`)
  - `start_metadata` - Metadata to include in all events
  - `fun` - Function to execute, must return `{:ok, _}` or `{:error, _}`

  ## Events Emitted

  - `event ++ [:start]` - Before function execution
  - `event ++ [:stop]` - After successful completion
  - `event ++ [:exception]` - If function raises or throws
  """
  @spec span([atom(), ...], map(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def span(event, start_metadata, fun) when is_list(event) and is_map(start_metadata) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      event ++ [:start],
      %{system_time: System.system_time()},
      start_metadata
    )

    try do
      result = fun.()
      duration = System.monotonic_time() - start_time
      result_atom = if is_tuple(result), do: elem(result, 0), else: :ok

      :telemetry.execute(
        event ++ [:stop],
        %{duration: duration},
        Map.put(start_metadata, :result, result_atom)
      )

      result
    rescue
      e ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          event ++ [:exception],
          %{duration: duration},
          Map.merge(start_metadata, %{kind: :error, reason: e})
        )

        reraise e, __STACKTRACE__
    catch
      kind, reason ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          event ++ [:exception],
          %{duration: duration},
          Map.merge(start_metadata, %{kind: kind, reason: reason})
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end
end
