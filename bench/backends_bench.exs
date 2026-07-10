defmodule ExMaude.Bench.Backends do
  @moduledoc false

  alias ExMaude.Backend

  @warmup 2
  @time 10

  @spec run() :: :ok
  def run do
    maude_path = ExMaude.Binary.path()
    servers = start_available_backends(maude_path)

    if servers == [] do
      raise "no ExMaude backend could be started"
    end

    try do
      Benchee.run(scenarios(servers),
        warmup: @warmup,
        time: @time,
        parallel: 1,
        memory_time: 2,
        formatters: [
          Benchee.Formatters.Console,
          {Benchee.Formatters.Markdown,
           file: "bench/output/backend_comparison.md",
           description: benchmark_description(servers)}
        ]
      )
    after
      Enum.each(servers, fn {_, module, server} -> safe_stop(module, server) end)
    end

    :ok
  end

  defp start_available_backends(maude_path) do
    [:port, :cnode, :nif]
    |> Enum.filter(&benchmarkable?/1)
    |> Enum.flat_map(fn backend ->
      module = backend_module(backend)

      case module.start_link(maude_path: maude_path, use_pty: false) do
        {:ok, server} ->
          IO.puts("#{backend}: ready")
          [{backend, module, server}]

        {:error, reason} ->
          IO.puts("#{backend}: skipped (#{inspect(reason)})")
          []
      end
    end)
  end

  defp benchmarkable?(:cnode), do: Backend.available?(:cnode) and Node.alive?()
  defp benchmarkable?(backend), do: Backend.available?(backend)

  defp backend_module(:port), do: ExMaude.Backend.Port
  defp backend_module(:cnode), do: ExMaude.Backend.CNode
  defp backend_module(:nif), do: ExMaude.Backend.NIF

  defp scenarios(servers) do
    large_term = build_large_term(100)

    Enum.reduce(servers, %{}, fn {name, module, server}, scenarios ->
      Map.merge(scenarios, %{
        "#{name}: one reduce" => fn ->
          module.execute(server, "reduce in NAT : 1 + 1 .")
        end,
        "#{name}: 100 reduces" => fn ->
          for i <- 1..100 do
            module.execute(server, "reduce in NAT : #{i} + #{i} .")
          end
        end,
        "#{name}: large term" => fn ->
          module.execute(server, "reduce in NAT : #{large_term} .")
        end
      })
    end)
  end

  defp build_large_term(1), do: "1"
  defp build_large_term(n), do: "(#{build_large_term(n - 1)} + 1)"

  defp safe_stop(module, server) do
    module.stop(server)
  catch
    :exit, _ -> :ok
  end

  defp benchmark_description(servers) do
    backends = Enum.map_join(servers, ", ", fn {name, _, _} -> to_string(name) end)

    """
    # ExMaude backend comparison

    Backends measured: #{backends}.

    Workers are started and made ready before Benchee begins. Timed functions
    include command transport, Maude evaluation, and response parsing; they do
    not include worker or Maude startup. Results are specific to this machine
    and should not be treated as a portable ranking.
    """
  end
end

ExMaude.Bench.Backends.run()
