alias ExMaude.Verification.Cancellation
alias ExMaude.Verification.SearchRun

{:ok, _} = Application.ensure_all_started(:ex_maude)
[] = Application.spec(:ex_maude, :mod)

owned = fn ->
  Enum.filter(Process.list(), fn pid ->
    case :proc_lib.translate_initial_call(pid) do
      {module, _, _} -> String.starts_with?(Atom.to_string(module), "Elixir.ExMaude.")
      _ -> false
    end
  end)
end

[] = owned.()
children = for id <- [:first, :second], do: Supervisor.child_spec({Cancellation, []}, id: id)
{:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
instances = Supervisor.which_children(supervisor) |> Map.new(fn {id, pid, _, _} -> {id, pid} end)
model = "mod ARCHIVE-CANCEL is protecting NAT . rl [next] : N:Nat => s(N:Nat) . endm\n"

query = %{
  module: "ARCHIVE-CANCEL",
  initial: "0",
  pattern: "0",
  max_depth: :unbounded,
  max_solutions: 2
}

path = System.fetch_env!("MAUDE_PATH")
:ok = Cancellation.request(instances.first)
{:ok, stopped} = SearchRun.run(model, query, maude_path: path, cancellation: instances.first)

%{
  termination: :cancelled,
  solutions: [],
  trace: nil,
  states_explored: nil,
  error: %ExMaude.Error{type: :cancelled}
} = stopped

{:ok, completed} =
  SearchRun.run(model, %{query | max_depth: 1, max_solutions: 1},
    maude_path: path,
    cancellation: instances.second
  )

%{termination: :solution_limit, solutions: [%{state_num: 0}]} = completed
true = stopped.model_digest == completed.model_digest
false = stopped.session_id == completed.session_id
{:error, %ExMaude.Error{type: :validation}} = Cancellation.request(instances.first)
:ok = Supervisor.stop(supervisor)
false = Process.alive?(instances.first)
false = Process.alive?(instances.second)
[] = owned.()
File.write!("receipts.etf", :erlang.term_to_binary({stopped, completed}))

IO.puts(
  "Offline installed archive consumer: passive loading, two instances, typed cancellation and supervisor closure passed"
)
