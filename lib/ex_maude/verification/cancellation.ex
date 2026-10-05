defmodule ExMaude.Verification.Cancellation do
  @moduledoc """
  A host-supervised, single-use cancellation instance for an isolated search.

  Pass the PID returned by `start_link/1` as `:cancellation` to
  `ExMaude.Verification.SearchRun.run/3`. `request/1` records a request, including
  before worker registration. It does not return a search receipt. Registered
  workers are retired synchronously; the run settles its typed receipt after
  closure. A request after closure is refused. Hosts assign distinct child IDs
  when supervising multiple instances. No instance starts on library loading.
  """

  use GenServer, restart: :temporary

  alias ExMaude.Backend.Port
  alias ExMaude.Error

  @doc "Starts an unregistered single-use instance; accepts GenServer start options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, nil, opts)

  @doc """
  Records cancellation, retiring a registered worker before acknowledgment.

  `:ok` acknowledges the request. Preparation may still be running; await the
  SearchRun receipt for its outcome. Closed instances return a validation error.
  Lost instances return a pool error. Repeated requests before closure are safe.
  """
  @spec request(pid()) :: :ok | {:error, Error.t()}
  def request(instance), do: call(instance, :request)

  @doc false
  @spec claim(pid()) :: :ok | {:error, Error.t()}
  def claim(instance), do: call(instance, :claim)

  @doc false
  @spec bind(pid(), pid()) :: :ok | :cancelled | {:error, Error.t()}
  def bind(instance, worker), do: call(instance, {:bind, worker})

  @doc false
  @spec finish(pid()) :: {:ok, :complete | :cancelled} | {:error, Error.t()}
  def finish(instance), do: call(instance, :finish)

  @impl GenServer
  def init(nil) do
    Process.flag(:trap_exit, true)
    {:ok, %{owner: nil, monitor: nil, worker: nil, requested: false, closed: false}}
  end

  @impl GenServer
  def handle_call(:claim, {owner, _}, %{owner: nil, closed: false} = state) do
    {:reply, :ok, %{state | owner: owner, monitor: Process.monitor(owner)}}
  end

  def handle_call(:request, _, %{closed: false} = state) do
    retire(state.worker)
    {:reply, :ok, %{state | requested: true, worker: nil}}
  end

  def handle_call(
        {:bind, worker},
        {owner, _},
        %{owner: owner, worker: nil, closed: false} = state
      )
      when is_pid(worker) and worker != owner and worker != self() do
    if state.requested do
      retire(worker)
      {:reply, :cancelled, state}
    else
      {:reply, :ok, %{state | worker: worker}}
    end
  end

  def handle_call(:finish, {owner, _}, %{owner: owner, closed: false} = state) do
    outcome = if state.requested, do: :cancelled, else: :complete
    {:reply, {:ok, outcome}, close(state)}
  end

  def handle_call(_, _, state) do
    {:reply, {:error, Error.new(:validation, "cancellation instance is unavailable to this run")},
     state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, owner, _}, %{monitor: ref, owner: owner} = state),
    do: {:noreply, close(state)}

  def handle_info(_, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_, state), do: retire(state.worker)

  defp close(state) do
    retire(state.worker)
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    %{state | owner: nil, monitor: nil, worker: nil, closed: true}
  end

  defp retire(nil), do: :ok

  defp retire(worker) do
    if Process.alive?(worker), do: Port.stop(worker)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp call(instance, message) when is_pid(instance) do
    GenServer.call(instance, message, :infinity)
  catch
    :exit, reason -> {:error, Error.pool_error(reason)}
  end

  defp call(_, _), do: {:error, Error.new(:validation, "cancellation instance must be a PID")}
end
