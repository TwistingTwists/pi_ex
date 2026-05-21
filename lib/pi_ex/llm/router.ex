defmodule PiEx.LLM.Router do
  @moduledoc """
  Configurable LLM runtime for PiEx.

  This module is the new LLM boundary for the agent loop.  It exposes the same
  `stream_fn/1` shape expected by `PiEx.Agent`, but the implementation is
  provider/model/account agnostic.

  ## Interface

      stream_fn =
        PiEx.LLM.Router.stream_fn(
          strategy: :weighted_random,
          routes: [
            [
              name: :openai_primary,
              backend: :req_llm,
              model: "openai:gpt-4.1",
              weight: 3,
              api_key: {:env, "OPENAI_API_KEY"},
              options: [temperature: 0.2]
            ],
            [
              name: :anthropic_fallback,
              backend: :req_llm,
              model: "anthropic:claude-sonnet-4-5-20250929",
              api_key: {:env, "ANTHROPIC_API_KEY"}
            ],
            [
              name: :gemini,
              backend: :req_llm,
              model: "google:gemini-2.5-pro",
              api_key: {:env, "GOOGLE_API_KEY"}
            ],
            [
              name: :local_openai_compatible,
              backend: :req_llm,
              model: %{
                provider: :openai,
                id: "qwen3-coder",
                base_url: "http://localhost:8000/v1",
                extra: %{openai_compatible_backend: :vllm}
              },
              api_key: "not-needed"
            ],
            [
              name: :cli_jsonl,
              backend: :jsonl_cli,
              command: ["my-llm-cli", "--stream-jsonl"],
              model: "my-cli-model"
            ]
          ]
        )

      {:ok, pid} = PiEx.start_session(stream_fn: stream_fn)

  A direct/single route form is also supported:

      PiEx.LLM.Router.stream_fn(model: "anthropic:claude-haiku-4-5")

  ## Features and support plan

    * Any ReqLLM provider/model: pass any ReqLLM model input string, tuple,
      `%LLMDB.Model{}`, or inline map through `:model`.
    * OpenAI-compatible endpoints: use an inline ReqLLM model map with
      `provider: :openai` and `base_url`.
    * Anthropic and Google: use ReqLLM provider ids such as `anthropic:*` and
      `google:*` plus per-route keys/options.
    * CLI JSONL backends: `backend: :jsonl_cli` spawns a configured command and
      consumes newline-delimited JSON events.
    * Streaming UI deltas: content chunks are broadcast as `:message_delta`;
      thinking chunks as `:thinking_delta`; raw chunks can be emitted with
      `emit_chunks?: true`.
    * Tool calling: PiEx tools are converted to `ReqLLM.Tool`s; ReqLLM/CLI tool
      calls are normalized back to `PiEx.Chat.ToolCall`.
    * Account routing/load balancing: configure multiple routes for the same
      model with different keys/accounts and select via `:fallback`,
      `:round_robin`, or `:weighted_random`.
    * Fallback: failed routes are tried in selection order when `fallback?: true`
      (default), so provider/account outages can fail over.
    * Per-route options: `:options` are passed to ReqLLM; `:provider_options` are
      merged into ReqLLM provider options; secrets can come from env/application/
      function values.
    * Future-ready health/rate limiting: route names/weights/account metadata let
      a later supervisor add circuit breakers and quota-aware selection without
      changing the agent API.

  ## CLI JSONL protocol

  The CLI receives one JSON request on stdin:

      {
        "messages": [...],
        "system_prompt": "...",
        "tools": [...],
        "model": "...",
        "cwd": "...",
        "options": {...}
      }

  It should emit one JSON object per line on stdout. Supported event shapes:

      {"type":"content", "text":"hello"}
      {"type":"message_delta", "delta":"hello"}
      {"type":"thinking", "text":"reasoning"}
      {"type":"tool_call", "id":"call_1", "name":"read", "arguments":{"path":"mix.exs"}}
      {"type":"tool_call_delta", "index":0, "id":"call_1", "name":"read", "arguments_delta":"{\"path\""}
      {"type":"meta", "finish_reason":"tool_calls", "usage":{"input_tokens":10}}
      {"type":"done"}

  """

  alias PiEx.Chat.Message

  @default_model "anthropic:claude-sonnet-4-20250514"
  @default_cli_timeout 300_000

  @type backend :: :req_llm | :jsonl_cli | :cli
  @type strategy :: :fallback | :first_available | :round_robin | :weighted_random
  @type secret ::
          String.t()
          | nil
          | {:env, String.t()}
          | {:system, String.t()}
          | {:application, atom(), atom()}
          | (-> String.t() | nil)

  @type route :: %{
          optional(:name) => atom() | String.t(),
          optional(:backend) => backend(),
          optional(:model) => ReqLLM.model_input(),
          optional(:weight) => pos_integer(),
          optional(:enabled?) => boolean(),
          optional(:api_key) => secret(),
          optional(:access_token) => secret(),
          optional(:options) => keyword(),
          optional(:provider_options) => keyword() | map(),
          optional(:command) => [String.t()] | String.t(),
          optional(:env) => map() | keyword(),
          optional(:cwd) => String.t(),
          optional(:timeout) => non_neg_integer() | :infinity,
          optional(:parser) => module() | {module(), keyword() | map()},
          optional(:stdin) => :pi_json | :none
        }

  @type config :: %{
          routes: [route()],
          strategy: strategy(),
          fallback?: boolean(),
          emit_chunks?: boolean()
        }

  @doc "Returns the implemented feature list for this module."
  @spec features() :: [String.t()]
  def features do
    [
      "ReqLLM provider/model passthrough",
      "OpenAI-compatible inline model support",
      "Anthropic/Google/OpenAI provider support through ReqLLM",
      "Extensible CLI parser backend with default JSONL and Shannon parsers",
      "PiEx event streaming callbacks",
      "Tool-call normalization",
      "Route/account load balancing",
      "Fallback across routes",
      "Per-route provider options and secrets"
    ]
  end

  @doc "Returns the staged support plan."
  @spec plan() :: [map()]
  def plan do
    [
      %{phase: 1, status: :implemented, item: "provider/model abstraction via ReqLLM routes"},
      %{phase: 1, status: :implemented, item: "streaming deltas and tool call collection"},
      %{phase: 1, status: :implemented, item: "CLI JSONL route for non-HTTP models"},
      %{
        phase: 1,
        status: :implemented,
        item: "round-robin, weighted-random, and ordered fallback routing"
      },
      %{phase: 2, status: :planned, item: "circuit breaker and health scoring per account"},
      %{phase: 2, status: :planned, item: "quota/rate-limit aware account selection"},
      %{phase: 3, status: :planned, item: "persistent route metrics and cost-aware routing"}
    ]
  end

  @doc "Build a `PiEx.Agent`-compatible stream function."
  @spec stream_fn(keyword() | map()) :: PiEx.Agent.stream_fn()
  def stream_fn(opts \\ []) do
    config = normalize_config!(opts)
    counter = :counters.new(1, [:atomics])

    fn messages, system_prompt, tools, call_opts ->
      call_with_config(config, counter, messages, system_prompt, tools, call_opts)
    end
  end

  @doc "Normalize router options into a config map. Useful for inspection/tests."
  @spec normalize_config!(keyword() | map()) :: config()
  def normalize_config!(opts) when is_list(opts) or is_map(opts) do
    opts = to_plain_map(opts)

    routes =
      opts
      |> Map.get(:routes)
      |> case do
        nil -> [Map.drop(opts, [:strategy, :fallback?, :emit_chunks?])]
        [] -> raise ArgumentError, "PiEx.LLM.Router requires at least one route"
        routes when is_list(routes) -> routes
      end
      |> Enum.map(&normalize_route!/1)
      |> Enum.filter(&Map.get(&1, :enabled?, true))

    if routes == [] do
      raise ArgumentError, "PiEx.LLM.Router has no enabled routes"
    end

    %{
      routes: routes,
      strategy: Map.get(opts, :strategy, :fallback),
      fallback?: Map.get(opts, :fallback?, true),
      emit_chunks?: Map.get(opts, :emit_chunks?, false)
    }
  end

  defp call_with_config(config, counter, messages, system_prompt, tools, call_opts) do
    routes = ordered_routes(config, counter)
    routes = if config.fallback?, do: routes, else: Enum.take(routes, 1)

    try_routes(routes, [], config, messages, system_prompt, tools, call_opts)
  end

  defp try_routes([], errors, _config, _messages, _system_prompt, _tools, _call_opts) do
    {:error, format_route_errors(errors)}
  end

  defp try_routes([route | rest], errors, config, messages, system_prompt, tools, call_opts) do
    case call_route(route, config, messages, system_prompt, tools, call_opts) do
      {:ok, msg} ->
        {:ok, msg}

      {:error, reason} ->
        try_routes(
          rest,
          [{route_name(route), reason} | errors],
          config,
          messages,
          system_prompt,
          tools,
          call_opts
        )
    end
  end

  defp call_route(%{backend: :req_llm} = route, config, messages, system_prompt, tools, call_opts) do
    call_req_llm(route, config, messages, system_prompt, tools, call_opts)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp call_route(%{backend: backend} = route, config, messages, system_prompt, tools, call_opts)
       when backend in [:jsonl_cli, :cli] do
    call_jsonl_cli(route, config, messages, system_prompt, tools, call_opts)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp call_req_llm(route, config, messages, system_prompt, tools, call_opts) do
    session_id = Keyword.get(call_opts, :session_id)
    llm_messages = PiEx.Turn.to_llm_messages(messages)
    req_tools = Enum.map(tools, &to_req_tool/1)
    model = route_model(route, call_opts)

    req_opts =
      route
      |> Map.get(:options, [])
      |> Keyword.merge(system_prompt: system_prompt, tools: req_tools)
      |> maybe_put(:api_key, resolve_secret(Map.get(route, :api_key)))
      |> merge_provider_options(route)

    case ReqLLM.stream_text(model, llm_messages, req_opts) do
      {:ok, stream_response} ->
        ReqLLM.StreamResponse.process_stream(stream_response,
          on_chunk: fn chunk -> maybe_broadcast_chunk(config, session_id, chunk) end,
          on_result: fn text -> broadcast_delta(session_id, text) end,
          on_thinking: fn text -> broadcast_thinking(session_id, text) end
        )
        |> case do
          {:ok, response} -> {:ok, build_assistant_message_from_response(response, route, model)}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_jsonl_cli(route, config, messages, system_prompt, tools, call_opts) do
    session_id = Keyword.get(call_opts, :session_id)
    model = route_model(route, call_opts)
    timeout = Map.get(route, :timeout, @default_cli_timeout)

    request = %{
      messages: Enum.map(messages, &message_to_map/1),
      system_prompt: system_prompt,
      tools: Enum.map(tools, &tool_to_map/1),
      model: model,
      cwd: Keyword.get(call_opts, :cwd) || Map.get(route, :cwd),
      options: Map.new(Map.get(route, :options, []))
    }

    with {:ok, parser_module, parser_state} <- init_cli_parser(route),
         {:ok, port} <- open_cli_port(route),
         true <- maybe_write_cli_request(port, route, request) do
      cli_loop(
        port,
        cli_state(model, parser_module, parser_state, route),
        config,
        session_id,
        timeout
      )
    else
      false -> {:error, "failed to write request to CLI route #{route_name(route)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp init_cli_parser(route) do
    {parser_module, parser_opts} = PiEx.LLM.CLI.Parser.normalize(Map.get(route, :parser))

    case parser_module.init(parser_opts) do
      {:ok, parser_state} ->
        {:ok, parser_module, parser_state}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, "invalid parser init result from #{inspect(parser_module)}: #{inspect(other)}"}
    end
  end

  defp maybe_write_cli_request(_port, %{stdin: :none}, _request), do: true

  defp maybe_write_cli_request(port, _route, request),
    do: Port.command(port, Jason.encode!(request) <> "\n")

  defp cli_loop(port, state, config, session_id, timeout) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        handle_cli_line_result(
          port,
          handle_cli_line(line, state, config, session_id),
          config,
          session_id,
          timeout
        )

      {^port, {:data, {:noeol, line}}} ->
        handle_cli_line_result(
          port,
          handle_cli_line(line, state, config, session_id),
          config,
          session_id,
          timeout
        )

      {^port, {:exit_status, 0}} ->
        {:ok, build_assistant_message_from_cli(state)}

      {^port, {:exit_status, status}} ->
        {:error, "CLI route exited with status #{status}"}
    after
      timeout ->
        close_port(port)
        {:error, "CLI route timed out after #{timeout}ms"}
    end
  end

  defp handle_cli_line_result(port, {:cont, state}, config, session_id, timeout) do
    cli_loop(port, state, config, session_id, timeout)
  end

  defp handle_cli_line_result(port, {:done, state}, _config, _session_id, _timeout) do
    close_port(port)
    {:ok, build_assistant_message_from_cli(state)}
  end

  defp handle_cli_line_result(port, {:error, reason}, _config, _session_id, _timeout) do
    close_port(port)
    {:error, reason}
  end

  defp handle_cli_line(line, state, config, session_id) do
    context = %{route: state.route, model: state.model}

    case state.parser_module.parse_line(line, state.parser_state, context) do
      {:ok, events, parser_state} when is_list(events) ->
        state = %{state | parser_state: parser_state}
        apply_cli_events(events, state, config, session_id)

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, "invalid parser result from #{inspect(state.parser_module)}: #{inspect(other)}"}
    end
  end

  defp apply_cli_events(events, state, config, session_id) do
    Enum.reduce_while(events, {:cont, state}, fn event, {:cont, state} ->
      case apply_cli_event(event, state, config, session_id) do
        {:cont, state} -> {:cont, {:cont, state}}
        {:done, state} -> {:halt, {:done, state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_cli_event(%PiEx.LLM.CLI.Event{type: :content} = event, state, config, session_id) do
    if config.emit_chunks?, do: broadcast(session_id, %{type: :llm_chunk, chunk: event})
    text = event.text || event.delta || ""
    broadcast_delta(session_id, text)
    {:cont, %{state | texts: [text | state.texts]}}
  end

  defp apply_cli_event(%PiEx.LLM.CLI.Event{type: :thinking} = event, state, config, session_id) do
    if config.emit_chunks?, do: broadcast(session_id, %{type: :llm_chunk, chunk: event})
    broadcast_thinking(session_id, event.text || event.delta || "")
    {:cont, state}
  end

  defp apply_cli_event(%PiEx.LLM.CLI.Event{type: :tool_call} = event, state, config, session_id) do
    if config.emit_chunks?, do: broadcast(session_id, %{type: :llm_chunk, chunk: event})
    {:cont, %{state | tool_calls: [normalize_cli_tool_call(event) | state.tool_calls]}}
  end

  defp apply_cli_event(
         %PiEx.LLM.CLI.Event{type: :tool_call_delta} = event,
         state,
         config,
         session_id
       ) do
    if config.emit_chunks?, do: broadcast(session_id, %{type: :llm_chunk, chunk: event})
    {:cont, apply_cli_tool_delta(state, event)}
  end

  defp apply_cli_event(%PiEx.LLM.CLI.Event{type: :meta} = event, state, config, session_id) do
    if config.emit_chunks?, do: broadcast(session_id, %{type: :llm_chunk, chunk: event})
    {:cont, merge_cli_meta(state, event)}
  end

  defp apply_cli_event(%PiEx.LLM.CLI.Event{type: :done} = event, state, config, session_id) do
    if config.emit_chunks?, do: broadcast(session_id, %{type: :llm_chunk, chunk: event})
    {:done, state}
  end

  defp apply_cli_event(%PiEx.LLM.CLI.Event{type: :error} = event, _state, config, session_id) do
    if config.emit_chunks?, do: broadcast(session_id, %{type: :llm_chunk, chunk: event})
    {:error, event.message || "CLI route error"}
  end

  defp apply_cli_event(%PiEx.LLM.CLI.Event{type: :ignore} = event, state, config, session_id) do
    if config.emit_chunks?, do: broadcast(session_id, %{type: :llm_chunk, chunk: event})
    {:cont, state}
  end

  defp cli_state(model, parser_module, parser_state, route) do
    %{
      texts: [],
      tool_calls: [],
      arg_buffers: %{},
      meta: %{},
      usage: nil,
      model: model,
      parser_module: parser_module,
      parser_state: parser_state,
      route: route
    }
  end

  defp apply_cli_tool_delta(state, event) do
    index = event.index || 0
    fragment = event.arguments_delta || ""
    existing = Map.get(state.arg_buffers, index, %{})

    updated = %{
      id: event.tool_call_id || existing[:id],
      name: event.tool_name || existing[:name],
      args: (existing[:args] || "") <> fragment
    }

    %{state | arg_buffers: Map.put(state.arg_buffers, index, updated)}
  end

  defp merge_cli_meta(state, event) do
    meta = Map.merge(state.meta, event.metadata || %{})
    usage = event.usage || state.usage
    %{state | meta: meta, usage: usage}
  end

  defp normalize_cli_tool_call(event) do
    %{
      id: event.tool_call_id || "tc_#{System.unique_integer([:positive])}",
      name: event.tool_name,
      arguments: parse_arguments(event.arguments || %{})
    }
  end

  defp open_cli_port(route) do
    case Map.fetch(route, :command) do
      {:ok, command} ->
        opts = [
          :binary,
          :use_stdio,
          :exit_status,
          :stderr_to_stdout,
          {:line, 65_536}
        ]

        opts = maybe_port_cd(opts, Map.get(route, :cwd))
        opts = maybe_port_env(opts, Map.get(route, :env))

        case command do
          [exe | args] ->
            with {:ok, exe} <- resolve_executable(exe) do
              {:ok, Port.open({:spawn_executable, exe}, [{:args, args} | opts])}
            end

          command when is_binary(command) ->
            {:ok, Port.open({:spawn, command}, opts)}

          _ ->
            {:error, "CLI route command must be a string or [executable | args]"}
        end

      :error ->
        {:error, "CLI route requires :command"}
    end
  end

  defp resolve_executable(exe) when is_binary(exe) do
    cond do
      String.contains?(exe, "/") -> {:ok, exe}
      resolved = System.find_executable(exe) -> {:ok, resolved}
      true -> {:error, "CLI route executable not found on PATH: #{exe}"}
    end
  end

  defp maybe_port_cd(opts, nil), do: opts
  defp maybe_port_cd(opts, cwd), do: [{:cd, cwd} | opts]

  defp maybe_port_env(opts, nil), do: opts

  defp maybe_port_env(opts, env) when is_map(env) or is_list(env) do
    env =
      env
      |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end)

    [{:env, env} | opts]
  end

  defp close_port(port) do
    Port.close(port)
  catch
    :error, _ -> :ok
  end

  defp normalize_config_value(value) when is_list(value),
    do: Enum.map(value, &normalize_config_value/1)

  defp normalize_config_value(value), do: value

  defp normalize_route!(route) when is_list(route) or is_map(route) do
    route = route |> to_plain_map() |> Map.new(fn {k, v} -> {k, normalize_config_value(v)} end)

    route
    |> Map.put_new(:backend, :req_llm)
    |> Map.put_new(:model, @default_model)
    |> Map.put_new(:weight, 1)
    |> Map.put_new(:enabled?, true)
    |> Map.put_new(:options, [])
    |> validate_route!()
  end

  defp validate_route!(%{backend: backend} = route)
       when backend in [:req_llm, :jsonl_cli, :cli] do
    route
  end

  defp validate_route!(route) do
    raise ArgumentError, "unsupported LLM route backend #{inspect(Map.get(route, :backend))}"
  end

  defp to_plain_map(value) when is_map(value), do: value
  defp to_plain_map(value) when is_list(value), do: Map.new(value)

  defp ordered_routes(%{strategy: :fallback, routes: routes}, _counter), do: routes
  defp ordered_routes(%{strategy: :first_available, routes: routes}, _counter), do: routes

  defp ordered_routes(%{strategy: :round_robin, routes: routes}, counter) do
    count = length(routes)
    current = :counters.get(counter, 1)
    :counters.add(counter, 1, 1)
    rotate(routes, rem(current, count))
  end

  defp ordered_routes(%{strategy: :weighted_random, routes: routes}, _counter) do
    selected = weighted_pick(routes)
    [selected | Enum.reject(routes, &(&1 == selected))]
  end

  defp ordered_routes(%{strategy: strategy}, _counter) do
    raise ArgumentError, "unsupported LLM routing strategy #{inspect(strategy)}"
  end

  defp rotate(routes, 0), do: routes

  defp rotate(routes, n) do
    {head, tail} = Enum.split(routes, n)
    tail ++ head
  end

  defp weighted_pick(routes) do
    total = Enum.reduce(routes, 0, fn route, acc -> acc + max(Map.get(route, :weight, 1), 1) end)
    ticket = :rand.uniform(total)

    {route, _} =
      Enum.reduce_while(routes, {nil, 0}, fn route, {_selected, acc} ->
        next = acc + max(Map.get(route, :weight, 1), 1)
        if ticket <= next, do: {:halt, {route, next}}, else: {:cont, {nil, next}}
      end)

    route || hd(routes)
  end

  defp route_model(route, call_opts) do
    Keyword.get(call_opts, :model) || Map.get(route, :model, @default_model)
  end

  defp to_req_tool(tool_mod) do
    ReqLLM.Tool.new!(
      name: tool_mod.name(),
      description: tool_mod.description(),
      parameter_schema: tool_mod.parameters(),
      callback: fn _args -> {:ok, "noop"} end
    )
  end

  defp merge_provider_options(req_opts, route) do
    provider_options = Map.get(route, :provider_options, [])
    access_token = resolve_secret(Map.get(route, :access_token))

    provider_options =
      provider_options
      |> provider_options_to_keyword()
      |> maybe_put(:access_token, access_token)

    if provider_options == [] do
      req_opts
    else
      existing = Keyword.get(req_opts, :provider_options, []) |> provider_options_to_keyword()
      Keyword.put(req_opts, :provider_options, Keyword.merge(existing, provider_options))
    end
  end

  defp provider_options_to_keyword(nil), do: []
  defp provider_options_to_keyword(value) when is_list(value), do: value
  defp provider_options_to_keyword(value) when is_map(value), do: Enum.into(value, [])

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, _key, ""), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp resolve_secret(nil), do: nil
  defp resolve_secret({:env, name}), do: System.get_env(name) || raise("missing env var #{name}")

  defp resolve_secret({:system, name}),
    do: System.get_env(name) || raise("missing env var #{name}")

  defp resolve_secret({:application, app, key}) do
    Application.get_env(app, key) ||
      raise "missing application env #{inspect(app)}, #{inspect(key)}"
  end

  defp resolve_secret(fun) when is_function(fun, 0), do: fun.()
  defp resolve_secret(value), do: value

  defp maybe_broadcast_chunk(%{emit_chunks?: true}, session_id, chunk) do
    broadcast(session_id, %{type: :llm_chunk, chunk: chunk})
  end

  defp maybe_broadcast_chunk(_config, _session_id, _chunk), do: :ok

  defp broadcast_delta(nil, _text), do: :ok
  defp broadcast_delta(_session_id, ""), do: :ok

  defp broadcast_delta(session_id, text),
    do: broadcast(session_id, %{type: :message_delta, delta: text})

  defp broadcast_thinking(nil, _text), do: :ok
  defp broadcast_thinking(_session_id, ""), do: :ok

  defp broadcast_thinking(session_id, text),
    do: broadcast(session_id, %{type: :thinking_delta, delta: text})

  defp broadcast(nil, _event), do: :ok
  defp broadcast(session_id, event), do: PiEx.Events.broadcast(session_id, event)

  defp build_assistant_message_from_response(response, route, model) do
    tool_calls =
      response
      |> ReqLLM.Response.tool_calls()
      |> Enum.map(&normalize_req_tool_call/1)

    text = ReqLLM.Response.text(response) || ""
    finish_reason = response.finish_reason

    attrs = %{
      content: text,
      tool_calls: tool_calls,
      model: model_to_string(model),
      provider: provider_to_string(model, route),
      stop_reason: stop_reason(tool_calls, finish_reason),
      usage: ReqLLM.Response.usage(response)
    }

    Ash.Changeset.for_create(Message, :create_assistant, attrs) |> Ash.create!()
  end

  defp build_assistant_message_from_cli(state) do
    text = state.texts |> Enum.reverse() |> Enum.join("")

    delta_calls =
      state.arg_buffers
      |> Enum.sort_by(fn {index, _} -> index end)
      |> Enum.map(fn {_index, %{id: id, name: name, args: raw_args}} ->
        %{
          id: id || "tc_#{System.unique_integer([:positive])}",
          name: name,
          arguments: parse_arguments(raw_args)
        }
      end)

    tool_calls =
      (Enum.reverse(state.tool_calls) ++ delta_calls)
      |> Enum.map(&to_pi_tool_call/1)

    finish_reason = state.meta["finish_reason"] || state.meta[:finish_reason]

    attrs = %{
      content: text,
      tool_calls: tool_calls,
      model: model_to_string(state.model),
      provider: "cli",
      stop_reason: stop_reason(tool_calls, finish_reason),
      usage: state.usage
    }

    Ash.Changeset.for_create(Message, :create_assistant, attrs) |> Ash.create!()
  end

  defp normalize_req_tool_call(tool_call) do
    tool_call
    |> ReqLLM.ToolCall.from_map()
    |> to_pi_tool_call()
  rescue
    _ ->
      tool_call
      |> normalize_cli_tool_call()
      |> to_pi_tool_call()
  end

  defp to_pi_tool_call(%{id: id, name: name, arguments: args}) do
    %PiEx.Chat.ToolCall{
      id: id || "tc_#{System.unique_integer([:positive])}",
      name: name,
      arguments: parse_arguments(args)
    }
  end

  defp to_pi_tool_call(%{"id" => id, "name" => name, "arguments" => args}) do
    to_pi_tool_call(%{id: id, name: name, arguments: args})
  end

  defp stop_reason(tool_calls, finish_reason) do
    normalized = normalize_finish_reason(finish_reason)

    cond do
      tool_calls != [] -> :tool_use
      normalized in [:tool_use, :tool_calls] -> :tool_use
      normalized in [:error] -> :error
      true -> :end_turn
    end
  end

  defp normalize_finish_reason(reason) when is_atom(reason), do: reason

  defp normalize_finish_reason(reason) when is_binary(reason) do
    case reason do
      "tool_use" -> :tool_use
      "tool_calls" -> :tool_calls
      "function_call" -> :tool_calls
      "error" -> :error
      _ -> String.to_atom(reason)
    end
  rescue
    _ -> :unknown
  end

  defp normalize_finish_reason(_), do: nil

  defp parse_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} when is_map(map) -> map
      {:ok, other} -> %{"value" => other}
      {:error, _} -> %{"raw" => args}
    end
  end

  defp parse_arguments(args) when is_map(args), do: args
  defp parse_arguments(_), do: %{}

  defp message_to_map(%Message{} = msg) do
    %{
      id: msg.id,
      role: msg.role,
      content: msg.content,
      tool_calls: Enum.map(msg.tool_calls || [], &Map.from_struct/1),
      tool_call_id: msg.tool_call_id,
      tool_name: msg.tool_name,
      is_error: msg.is_error
    }
  end

  defp tool_to_map(tool_mod) do
    %{
      name: tool_mod.name(),
      description: tool_mod.description(),
      parameters: tool_mod.parameters()
    }
  end

  defp model_to_string(%LLMDB.Model{id: id}) when is_binary(id), do: id
  defp model_to_string(model) when is_binary(model), do: model
  defp model_to_string(model), do: inspect(model)

  defp provider_to_string(%LLMDB.Model{provider: provider}, _route), do: to_string(provider)

  defp provider_to_string(model, _route) when is_binary(model),
    do: model |> String.split(":", parts: 2) |> hd()

  defp provider_to_string(%{provider: provider}, _route), do: to_string(provider)
  defp provider_to_string(_model, route), do: route |> Map.get(:backend, :req_llm) |> to_string()

  defp route_name(route),
    do: Map.get(route, :name) || Map.get(route, :model) || Map.get(route, :backend)

  defp format_route_errors(errors) do
    errors
    |> Enum.reverse()
    |> Enum.map_join("; ", fn {name, reason} -> "#{inspect(name)} failed: #{inspect(reason)}" end)
  end

  @doc "Returns the default model string."
  def default_model, do: @default_model
end
