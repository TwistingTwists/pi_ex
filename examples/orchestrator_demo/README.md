# Orchestrator Demo

A self-contained Elixir project showing how another application can use
`pi_ex_native` as a library and orchestrate a PiEx agent from its own GenServer.

## Run in IEx

```bash
cd examples/orchestrator_demo
mix deps.get
iex -S mix
```

```elixir
{:ok, runner} = OrchestratorDemo.start_demo()
:ok = OrchestratorDemo.prompt(runner, "Read sample.txt")
{:ok, response} = OrchestratorDemo.await_done(runner)
IO.puts(response)
OrchestratorDemo.events(runner) |> Enum.map(& &1.type)
```

The default demo uses `OrchestratorDemo.DemoLLM`, an offline deterministic LLM
that makes PiEx call the real `read` tool and then returns a final response.
That keeps the project runnable without API keys while still exercising the
PiEx agent/tool loop.

## Use your own LLM

Pass any `PiEx.Agent` compatible `stream_fn` to the runner:

```elixir
stream_fn = PiEx.LLM.stream_fn(model: "anthropic:claude-sonnet-4-20250514")
{:ok, runner} = OrchestratorDemo.AgentRunner.start_link(stream_fn: stream_fn, cwd: File.cwd!())
```
