defmodule AshAgentTools.Runtime do
  @moduledoc """
  Extended runtime execution engine that adds tool-calling capabilities to AshAgent.

  This module extends AshAgent.Runtime with multi-turn tool execution loops:
  1. Adds tool-calling loop when tools are configured
  2. Manages tool execution and iteration state
  3. Handles tool result processing and loop termination
  4. Handles single-turn execution for agents without tools

  ## Architecture

  This runtime is automatically used by `AshAgent.Runtime` when:
  1. `ash_agent_tools` is installed and started
  2. An agent has tools configured via the `tools` section

  Users should always call `AshAgent.Runtime.call/2` - it will automatically
  delegate to this module when appropriate.

  This runtime uses the public `AshAgent.Extension` API to access all
  core functionality, ensuring loose coupling between the packages.

  ## Configuration

  This module uses the public `AshAgent.Info.agent_config/1` API to retrieve
  all agent configuration, including the `:context_module` which is read from
  the `:ash_agent` application configuration.

  ## Example

      # Always use AshAgent.Runtime, regardless of tools
      AshAgent.Runtime.call(MyAgent, args)  # Works with or without tools

  This runtime can also be called directly for advanced use cases, but this is
  not recommended for normal usage.
  """

  alias AshAgent.{Context, Extension}
  alias AshAgentTools.{Info, ToolConverter}
  alias AshAgentTools.Runtime.ToolExecutor
  alias Spark.Dsl.Extension, as: SparkExtension

  defmodule LoopState do
    @moduledoc false
    defstruct [
      :config,
      :module,
      :context,
      :prompt,
      :schema,
      :tools,
      :tool_config,
      :metadata
    ]
  end

  def handles?(module) do
    SparkExtension.get_persisted(module, :requires_tool_runtime?, false)
  rescue
    _ -> false
  end

  @doc """
  Calls an agent with the given arguments.

  Executes either a single-turn call (if no tools) or a multi-turn tool-calling loop
  (if tools are configured), all within this runtime.

  Returns `{:ok, result}` where result is an instance of the agent's output TypedStruct,
  or `{:error, reason}` on failure.

  ## Examples

      # Define an agent resource with tools
      defmodule MyApp.ResearchAgent do
        use Ash.Resource,
          domain: MyApp.Domain,
          extensions: [AshAgent.Resource, AshAgentTools.Resource]

        defmodule Answer do
          use Ash.TypedStruct

          typed_struct do
            field :content, :string, enforce: true
          end
        end

        agent do
          client "anthropic:claude-3-5-sonnet"
          output Answer
          prompt "You are a helpful research assistant. Answer: {{ question }}"
        end

        agent_tools do
          tool :search do
            argument :query, :string
            run fn %{query: query}, _context ->
              {:ok, "Search results for: \#{query}"}
            end
          end
        end

        input do
          argument :question, :string
        end
      end

      # Call the agent using AshAgent.Runtime (automatically delegates to this module)
      {:ok, answer} = AshAgent.Runtime.call(MyApp.ResearchAgent, question: "What is Elixir?")
      answer.content
      #=> "Elixir is a dynamic, functional programming language..."

  """
  @spec call(module(), keyword() | map()) :: {:ok, struct()} | {:error, term()}
  def call(module, args) do
    call(module, args, [])
  end

  @spec call(module(), keyword() | map(), keyword() | map()) :: {:ok, struct()} | {:error, term()}
  def call(module, args, runtime_opts) do
    # Always use this runtime for agents that may have tools
    # The runtime will handle both tool-calling and single-turn execution
    with {:ok, config} <- get_agent_config(module),
         {:ok, config} <- apply_runtime_overrides(config, runtime_opts),
         :ok <- validate_provider_capabilities(config, :call) do
      call_with_hooks(config, module, args)
    else
      {:error, _} = error ->
        error
    end
  end

  defp call_with_hooks(config, module, args) do
    context = Extension.build_context(module, args)

    with {:ok, context} <- Extension.execute_hook(config.hooks, :before_call, context),
         {:ok, prompt} <- Extension.render_prompt(config.prompt, context.input, config),
         context = Extension.with_prompt(context, prompt),
         {:ok, context} <- Extension.execute_hook(config.hooks, :after_render, context),
         {:ok, schema} <- Extension.build_schema(config) do
      case execute_with_tools(config, module, context, prompt, schema) do
        {:ok, result} ->
          context = Extension.with_response(context, result)

          case Extension.execute_hook(config.hooks, :after_call, context) do
            {:ok, context} -> {:ok, context.response}
            {:error, transformed_error} -> {:error, transformed_error}
          end

        {:error, error} = result ->
          context = Extension.with_error(context, error)

          case Extension.execute_hook(config.hooks, :on_error, context) do
            {:ok, _context} -> result
            {:error, transformed_error} -> {:error, transformed_error}
          end
      end
    else
      {:error, error} = result ->
        context = Extension.with_error(context, error)

        case Extension.execute_hook(config.hooks, :on_error, context) do
          {:ok, _context} -> result
          {:error, transformed_error} -> {:error, transformed_error}
        end
    end
  end

  defp execute_with_tools(config, module, context, prompt, schema) do
    if config.tools != [] do
      execute_with_tool_calling(config, module, context, prompt, schema)
    else
      execute_single_turn(config, module, context, prompt, schema)
    end
  end

  defp execute_single_turn(config, module, context, prompt, schema) do
    metadata = Extension.telemetry_metadata(config, module, :call)
    metadata = Map.put(metadata, :input, context.input)

    rendered_prompt =
      if prompt do
        case Extension.render_prompt(prompt, context.input, config) do
          {:ok, rendered} -> rendered
          {:error, _} -> nil
        end
      else
        nil
      end

    if rendered_prompt do
      emit_prompt_rendered(metadata, rendered_prompt)
    end

    ctx = config.context_module.new(context.input, system_prompt: rendered_prompt)

    emit_llm_request(metadata, ctx, nil)

    response_result =
      Extension.generate_object(
        module,
        config.client,
        prompt,
        schema,
        config.client_opts,
        context,
        provider_override: config.provider
      )

    emit_llm_response(metadata, response_result, ctx, nil)

    {result, enriched_metadata} =
      case response_result do
        {:ok, response} ->
          result = Extension.parse_response(config.output_type, response)
          enriched_metadata = build_single_turn_metadata(metadata, result, response, ctx)
          {result, enriched_metadata}

        error ->
          {error, Map.put(metadata, :context, ctx)}
      end

    :telemetry.execute([:ash_agent, :call, :stop], %{}, enriched_metadata)
    normalize_result(result)
  end

  defp execute_with_tool_calling(config, module, context, prompt, schema) do
    metadata = Extension.telemetry_metadata(config, module, :call)
    metadata = Map.put(metadata, :input, context.input)

    tools = ToolConverter.to_json_schema(config.tools)
    tool_config = config.tool_config

    rendered_prompt =
      if prompt do
        case Extension.render_prompt(prompt, context.input, config) do
          {:ok, rendered} -> rendered
          {:error, _} -> nil
        end
      else
        nil
      end

    ctx = config.context_module.new(context.input, system_prompt: rendered_prompt)

    loop_state = %LoopState{
      config: config,
      module: module,
      context: context,
      prompt: prompt,
      schema: schema,
      tools: tools,
      tool_config: tool_config,
      metadata: metadata
    }

    {result, final_ctx} = execute_tool_calling_loop(loop_state, ctx)

    usage = config.context_module.get_cumulative_tokens(final_ctx)

    enriched_metadata =
      case result do
        {:ok, parsed} ->
          metadata
          |> Map.put(:result, parsed)
          |> Map.put(:context, final_ctx)
          |> Map.put(:usage, usage)

        _ ->
          metadata
          |> Map.put(:context, final_ctx)
          |> Map.put(:usage, usage)
      end

    :telemetry.execute([:ash_agent, :call, :stop], %{}, enriched_metadata)
    normalize_result(result)
  end

  defp execute_tool_calling_loop(%LoopState{} = state, ctx) do
    iter_number = ctx.current_iteration
    iter_started_at = System.monotonic_time()

    case execute_on_iteration_start_hook(ctx, state) do
      {:ok, _ctx} ->
        {result, updated_ctx} = execute_tool_calling_iteration(state, ctx)
        emit_iteration_stop(iter_number, result, ctx, updated_ctx, iter_started_at)
        execute_on_iteration_complete_hook(updated_ctx, result, state)
        {result, updated_ctx}

      {:error, _reason} = error ->
        emit_iteration_stop(iter_number, error, ctx, ctx, iter_started_at)
        {error, ctx}
    end
  end

  defp execute_tool_calling_iteration(%LoopState{} = state, ctx) do
    :telemetry.execute(
      [:ash_agent, :iteration, :start],
      %{},
      %{
        agent: state.module,
        iteration: ctx.current_iteration
      }
    )

    ctx = execute_prepare_context_hook(ctx, state)
    messages = state.config.context_module.to_messages(ctx)
    messages = execute_prepare_messages_hook(messages, ctx, state)
    current_prompt = nil

    emit_llm_request(state.metadata, ctx, state)

    case Extension.generate_object(
           state.module,
           state.config.client,
           current_prompt,
           state.schema,
           state.config.client_opts,
           state.context,
           tools: state.tools,
           messages: messages,
           provider_override: state.config.provider
         ) do
      {:ok, response} = ok_resp ->
        emit_llm_response(state.metadata, ok_resp, ctx, state)
        {result, updated_ctx} = handle_llm_response(response, state, ctx)
        {result, updated_ctx}

      {:error, _reason} = error ->
        emit_llm_response(state.metadata, error, ctx, state)
        {result, updated_ctx} = handle_tool_calling_error(error, state, ctx)
        {result, updated_ctx}
    end
  end

  defp handle_tool_calling_error(error, %LoopState{} = state, ctx) do
    if state.tool_config.on_error == :continue do
      ctx = state.config.context_module.add_assistant_message(ctx, "", [])
      ctx = add_iteration(ctx)

      execute_tool_calling_loop(state, ctx)
    else
      {error, ctx}
    end
  end

  defp handle_llm_response(response, %LoopState{} = state, ctx) do
    tool_calls = extract_tool_calls(response, state.config.provider)
    content = extract_content(response, state.config.provider)

    ctx = state.config.context_module.add_assistant_message(ctx, content, tool_calls)

    ctx = state.config.context_module.add_llm_call_timing(ctx)

    ctx =
      case Extension.response_usage(state.config.provider, response) do
        nil ->
          ctx

        usage ->
          state.config.context_module.add_token_usage(ctx, usage)
      end

    case tool_calls do
      [] ->
        final_result = Extension.parse_response(state.config.output_type, response)
        {final_result, ctx}

      calls when is_list(calls) ->
        emit_tool_decision_telemetry(calls, state, ctx)
        execute_tool_calls(calls, state, ctx)
    end
  end

  defp execute_tool_calls(tool_calls, %LoopState{} = state, ctx) do
    tool_call_start_times = emit_tool_call_start_telemetry(tool_calls, state, ctx)

    runtime_context = %{
      agent: state.module,
      domain: get_domain(state.module),
      actor: Map.get(state.context, :actor),
      tenant: Map.get(state.context, :tenant)
    }

    results = ToolExecutor.execute_tools(tool_calls, state.config.tools, runtime_context)

    end_time = DateTime.utc_now()

    tool_calls_with_timing =
      enrich_tool_calls_with_timing(tool_calls, tool_call_start_times, end_time)

    emit_tool_call_complete_telemetry(results, tool_calls, state, ctx)

    results = execute_prepare_tool_results_hook(results, tool_calls, ctx, state)
    ctx = update_tool_calls_timing(ctx, tool_calls_with_timing)

    process_tool_results(results, state, ctx)
  end

  defp emit_tool_decision_telemetry(tool_calls, %LoopState{} = state, ctx) do
    chosen = List.first(tool_calls)

    :telemetry.execute(
      [:ash_agent, :tool_call, :decision],
      %{},
      %{
        agent: state.module,
        iteration: ctx.current_iteration,
        tool_name: chosen && chosen.name,
        considered_tools: Enum.map(tool_calls, & &1.name)
      }
    )
  end

  defp emit_tool_call_start_telemetry(tool_calls, state, ctx) do
    Enum.map(tool_calls, fn tool_call ->
      start_time = DateTime.utc_now()

      :telemetry.execute(
        [:ash_agent, :tool_call, :start],
        %{},
        %{
          agent: state.module,
          iteration: ctx.current_iteration,
          tool_name: tool_call.name,
          tool_id: tool_call.id,
          arguments: tool_call.arguments
        }
      )

      {tool_call.id, start_time}
    end)
    |> Map.new()
  end

  defp enrich_tool_calls_with_timing(tool_calls, start_times, end_time) do
    Enum.map(tool_calls, fn tool_call ->
      start_time = Map.get(start_times, tool_call.id)
      duration_ms = if start_time, do: DateTime.diff(end_time, start_time, :millisecond), else: 0

      Map.merge(tool_call, %{
        started_at: start_time,
        completed_at: end_time,
        duration_ms: duration_ms
      })
    end)
  end

  defp emit_tool_call_complete_telemetry(results, tool_calls, state, ctx) do
    Enum.each(results, fn {tool_call_id, result} ->
      tool_call = Enum.find(tool_calls, &(&1.id == tool_call_id))

      case result do
        {:ok, value} ->
          :telemetry.execute(
            [:ash_agent, :tool_call, :complete],
            %{},
            %{
              agent: state.module,
              iteration: ctx.current_iteration,
              tool_name: tool_call && tool_call.name,
              tool_id: tool_call_id,
              result: value,
              status: :success
            }
          )

        {:halt, value} ->
          :telemetry.execute(
            [:ash_agent, :tool_call, :complete],
            %{},
            %{
              agent: state.module,
              iteration: ctx.current_iteration,
              tool_name: tool_call && tool_call.name,
              tool_id: tool_call_id,
              result: value,
              status: :halt
            }
          )

        {:error, reason} ->
          :telemetry.execute(
            [:ash_agent, :tool_call, :complete],
            %{},
            %{
              agent: state.module,
              iteration: ctx.current_iteration,
              tool_name: tool_call && tool_call.name,
              tool_id: tool_call_id,
              error: reason,
              status: :error
            }
          )
      end
    end)
  end

  defp process_tool_results(results, state, ctx) do
    halt_result =
      Enum.find_value(results, fn
        {_id, {:halt, value}} -> value
        _ -> nil
      end)

    cond do
      halt_result != nil ->
        ctx = add_tool_results(ctx, results)
        final_result = {:ok, halt_result}
        {final_result, ctx}

      has_tool_errors?(results, state.tool_config) ->
        {{:error, Extension.llm_error("Tool execution failed")}, ctx}

      true ->
        ctx = add_tool_results(ctx, results)
        next_iteration_number = ctx.current_iteration + 1

        new_iteration = %{
          number: next_iteration_number,
          messages: [],
          tool_calls: [],
          started_at: DateTime.utc_now(),
          completed_at: nil,
          metadata: %{}
        }

        ctx =
          update_context_iterations(ctx, %{
            iterations: ctx.iterations ++ [new_iteration],
            current_iteration: next_iteration_number
          })

        execute_tool_calling_loop(state, ctx)
    end
  end

  defp has_tool_errors?(results, tool_config) do
    tool_config.on_error == :halt and
      Enum.any?(results, fn
        {_, {_, :error}} -> true
        _ -> false
      end)
  end

  defp add_iteration(ctx) do
    next_iteration_number = ctx.current_iteration + 1

    new_iteration = %{
      number: next_iteration_number,
      messages: [],
      tool_calls: [],
      started_at: DateTime.utc_now(),
      completed_at: nil,
      metadata: %{}
    }

    update_context_iterations(ctx, %{
      iterations: ctx.iterations ++ [new_iteration],
      current_iteration: next_iteration_number
    })
  end

  defp update_context_iterations(ctx, attrs) do
    ctx.__struct__.persist(ctx, attrs)
  end

  defp add_tool_results(ctx, results) do
    if function_exported?(ctx.__struct__, :add_tool_results, 2) do
      ctx.__struct__.add_tool_results(ctx, results)
    else
      ctx
    end
  end

  defp update_tool_calls_timing(ctx, tool_calls_with_timing) do
    if function_exported?(ctx.__struct__, :update_tool_calls_timing, 2) do
      ctx.__struct__.update_tool_calls_timing(ctx, tool_calls_with_timing)
    else
      ctx
    end
  end

  defp extract_content(response, provider) do
    # Try provider-specific extraction first
    provider_module = resolve_provider_module(provider)

    if provider_module && function_exported?(provider_module, :extract_content, 1) do
      case provider_module.extract_content(response) do
        {:ok, content} -> content
        {:error, _reason} -> ""
        :default -> extract_content_default(response)
      end
    else
      extract_content_default(response)
    end
  end

  # Generic fallback for extracting content from responses
  # Tries common patterns but providers should implement extract_content/1 for best results
  defp extract_content_default(response) when is_binary(response), do: response

  defp extract_content_default(%{content: content}) when is_binary(content), do: content
  defp extract_content_default(%{"content" => content}) when is_binary(content), do: content

  defp extract_content_default(%{content: content}) when is_list(content) do
    extract_text_from_content(content)
  end

  defp extract_content_default(%{"content" => content}) when is_list(content) do
    extract_text_from_content(content)
  end

  # Try to extract from common response wrapper patterns
  defp extract_content_default(%{text: text}) when is_binary(text), do: text
  defp extract_content_default(%{"text" => text}) when is_binary(text), do: text

  defp extract_content_default(%{message: message}) when is_map(message) do
    extract_content_default(message)
  end

  defp extract_content_default(%{"message" => message}) when is_map(message) do
    extract_content_default(message)
  end

  defp extract_content_default(_response), do: ""

  defp extract_text_from_content([%{"type" => "text", "text" => text} | _]) when is_binary(text),
    do: text

  defp extract_text_from_content([%{type: "text", text: text} | _]) when is_binary(text), do: text
  defp extract_text_from_content([_ | rest]), do: extract_text_from_content(rest)
  defp extract_text_from_content([]), do: ""

  defp extract_tool_calls(response, provider) do
    # Try provider-specific extraction first
    provider_module = resolve_provider_module(provider)

    if provider_module && function_exported?(provider_module, :extract_tool_calls, 1) do
      case provider_module.extract_tool_calls(response) do
        {:ok, tool_calls} -> tool_calls
        {:error, _reason} -> []
        :default -> extract_tool_calls_default(response)
      end
    else
      extract_tool_calls_default(response)
    end
  end

  # Generic fallback for extracting tool calls from responses
  # Tries common patterns but providers should implement extract_tool_calls/1 for best results
  defp extract_tool_calls_default(%{tool_calls: tool_calls}) when is_list(tool_calls) do
    normalize_tool_calls(tool_calls)
  end

  defp extract_tool_calls_default(%{"tool_calls" => tool_calls}) when is_list(tool_calls) do
    normalize_tool_calls(tool_calls)
  end

  # Check nested response patterns
  defp extract_tool_calls_default(%{message: %{tool_calls: tool_calls}})
       when is_list(tool_calls) do
    normalize_tool_calls(tool_calls)
  end

  defp extract_tool_calls_default(%{"message" => %{"tool_calls" => tool_calls}})
       when is_list(tool_calls) do
    normalize_tool_calls(tool_calls)
  end

  defp extract_tool_calls_default(_response), do: []

  defp resolve_provider_module(provider) when is_atom(provider) do
    case Extension.resolve_provider(provider) do
      {:ok, module} -> module
      _ -> nil
    end
  end

  defp resolve_provider_module(provider) when is_binary(provider) do
    resolve_provider_module(String.to_existing_atom(provider))
  rescue
    ArgumentError -> nil
  end

  defp resolve_provider_module(provider_module) when is_atom(provider_module) do
    # Already a module
    if Code.ensure_loaded?(provider_module) do
      provider_module
    else
      nil
    end
  end

  defp resolve_provider_module(_provider), do: nil

  defp normalize_tool_calls(tool_calls) do
    tool_calls
    |> Enum.map(fn
      %{id: id, name: name, arguments: args} when is_binary(args) ->
        case Jason.decode(args) do
          {:ok, decoded} -> %{id: id, name: name, arguments: decoded}
          {:error, _} -> %{id: id, name: name, arguments: %{}}
        end

      %{"id" => id, "name" => name, "arguments" => args} when is_binary(args) ->
        case Jason.decode(args) do
          {:ok, decoded} -> %{id: id, name: name, arguments: decoded}
          {:error, _} -> %{id: id, name: name, arguments: %{}}
        end

      tool_call ->
        tool_call
    end)
    |> Enum.map(&normalize_tool_name/1)
  end

  defp normalize_tool_name(%{name: name} = tool_call) do
    %{tool_call | name: normalize_name(name)}
  end

  defp normalize_tool_name(tool_call), do: tool_call

  defp normalize_name(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> String.to_atom(name)
  end

  defp normalize_name(name), do: name

  defp get_domain(module) do
    case Ash.Resource.Info.domain(module) do
      nil -> nil
      domain -> domain
    end
  end

  @doc """
  Calls an agent with the given arguments, raising on error.

  Returns the result struct directly or raises an exception.
  """
  @spec call!(module(), keyword() | map()) :: struct() | no_return()
  def call!(module, args) do
    case call(module, args) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Streams an agent response with the given arguments.

  Executes either single-turn streaming (if no tools) or a streaming tool-calling loop
  (if tools are configured), all within this runtime.

  Returns `{:ok, stream}` where stream yields partial results,
  or `{:error, reason}` on failure.

  ## Examples

      # Stream from agent without tools
      {:ok, stream} = AshAgentTools.Runtime.stream(MyApp.ChatAgent, message: "Hello!")

      # The stream yields the complete structured result
      results = Enum.to_list(stream)
      [reply] = results
      reply.content
      #=> "Hello! How can I assist you today?"

  """
  @spec stream(module(), keyword() | map()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(module, args) do
    stream(module, args, [])
  end

  @spec stream(module(), keyword() | map(), keyword() | map()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream(module, args, runtime_opts) do
    # Always use this runtime for agents that may have tools
    # The runtime will handle both tool-calling and single-turn streaming
    with {:ok, config} <- get_agent_config(module),
         {:ok, config} <- apply_runtime_overrides(config, runtime_opts),
         :ok <- validate_provider_capabilities(config, :stream) do
      if config.tools != [] do
        {:error,
         Extension.validation_error(
           "Streaming with tools is not supported yet",
           %{agent: module}
         )}
      else
        stream_with_hooks(config, module, args)
      end
    else
      {:error, _} = error ->
        error
    end
  end

  defp stream_with_hooks(config, module, args) do
    context = Extension.build_context(module, args)

    with {:ok, context} <- Extension.execute_hook(config.hooks, :before_call, context),
         {:ok, prompt} <- render_prompt(config, context.input),
         context = Extension.with_prompt(context, prompt),
         {:ok, context} <- Extension.execute_hook(config.hooks, :after_render, context),
         {:ok, schema} <- build_schema(config),
         {:ok, stream_response} <-
           Extension.stream_object(
             module,
             config.client,
             context.rendered_prompt,
             schema,
             config.client_opts,
             context,
             provider_override: config.provider
           ) do
      telemetry_span_context = make_ref()
      start_metadata = telemetry_metadata(config, module, :stream)
      start_metadata = Map.put(start_metadata, :telemetry_span_context, telemetry_span_context)
      start_metadata = Map.put(start_metadata, :input, context.input)

      :telemetry.execute([:ash_agent, :stream, :start], %{}, start_metadata)

      :telemetry.execute(
        [:ash_agent, :llm, :request],
        %{},
        Map.put(start_metadata, :iteration, 1)
      )

      start_time = System.monotonic_time()
      stream = Extension.stream_to_structs(stream_response, config.output_type)

      wrapped_stream =
        Stream.transform(
          stream,
          fn -> {start_time, nil, 0} end,
          fn result, {started_at, _last, idx} ->
            context = Extension.with_response(context, result)

            delivered =
              case Extension.execute_hook(config.hooks, :after_call, context) do
                {:ok, context} -> context.response
                {:error, _} -> result
              end

            chunk_meta =
              start_metadata
              |> Map.put(:telemetry_span_context, telemetry_span_context)
              |> Map.put(:chunk, delivered)
              |> Map.put(:iteration, 1)

            :telemetry.execute([:ash_agent, :stream, :chunk], %{index: idx}, chunk_meta)

            {[delivered], {started_at, delivered, idx + 1}}
          end,
          fn {started_at, last_chunk, _idx} ->
            resp_meta =
              start_metadata
              |> Map.put(:telemetry_span_context, telemetry_span_context)
              |> Map.put(:status, :ok)
              |> Map.put(:response, last_chunk)

            :telemetry.execute([:ash_agent, :llm, :response], %{}, resp_meta)
            emit_stream_stop(telemetry_span_context, start_metadata, started_at, last_chunk, :ok)
            []
          end
        )

      {:ok, wrapped_stream}
    else
      {:error, error} = result ->
        context = Extension.with_error(context, error)

        case Extension.execute_hook(config.hooks, :on_error, context) do
          {:ok, _context} -> result
          {:error, transformed_error} -> {:error, transformed_error}
        end
    end
  end

  @doc """
  Streams an agent response with the given arguments, raising on error.

  Returns a stream that yields partial results or raises an exception.
  """
  @spec stream!(module(), keyword() | map()) :: Enumerable.t() | no_return()
  def stream!(module, args) do
    case stream(module, args) do
      {:ok, stream} -> stream
      {:error, error} -> raise error
    end
  end

  # Tool-specific agent configuration - extends base config with tools
  defp get_agent_config(module) do
    with {:ok, base_config} <- Extension.get_config(module) do
      tool_config = Info.tool_config(module)
      tools = Info.tools(module)

      # Use the context module from base_config (set by application config)
      # The AshAgentTools.Application sets this to AshAgentTools.Context on startup
      config =
        base_config
        |> Map.put(:tools, tools)
        |> Map.put(:tool_config, tool_config)
        |> Map.put(:profile, nil)

      {:ok, config}
    end
  rescue
    e ->
      {:error,
       Extension.config_error("Failed to load agent configuration", %{
         module: module,
         exception: e
       })}
  end

  defp apply_runtime_overrides(config, runtime_opts) do
    Extension.apply_runtime_overrides(config, runtime_opts)
  end

  defp validate_provider_capabilities(config, type) do
    Extension.validate_provider_capabilities(config, type)
  end

  @spec render_prompt(map(), keyword() | map()) :: {:ok, String.t()} | {:error, String.t()}
  defp render_prompt(%{prompt: nil}, _args), do: {:ok, nil}

  defp render_prompt(config, args) do
    Extension.render_prompt(config.prompt, args, config)
  end

  defp build_schema(config) do
    Extension.build_schema(config)
  end

  defp emit_prompt_rendered(metadata, prompt) do
    measurements = %{length: byte_size(prompt)}

    meta =
      (metadata || %{})
      |> Map.put(:timestamp, DateTime.utc_now())
      |> Map.put(:prompt_preview, String.slice(prompt, 0, 200))

    :telemetry.execute([:ash_agent, :prompt, :rendered], measurements, meta)
  end

  defp emit_llm_request(metadata, ctx, state) do
    meta =
      (metadata || %{})
      |> Map.put(:iteration, ctx.current_iteration)
      |> maybe_put_tool_config(state)
      |> Map.put(:timestamp, DateTime.utc_now())

    :telemetry.execute([:ash_agent, :llm, :request], %{}, meta)
  end

  @dialyzer {:nowarn_function, emit_llm_response: 4}
  defp emit_llm_response(metadata, response_result, ctx, state) do
    status =
      case response_result do
        {:ok, _} -> :ok
        {:error, _} -> :error
        _ -> :unknown
      end

    meta =
      (metadata || %{})
      |> Map.put(:iteration, ctx.current_iteration)
      |> maybe_put_tool_config(state)
      |> Map.put(:timestamp, DateTime.utc_now())
      |> Map.put(:status, status)

    :telemetry.execute([:ash_agent, :llm, :response], %{}, meta)
  end

  defp maybe_put_tool_config(meta, %LoopState{} = state) do
    Map.put(meta, :tool_config, state.tool_config)
  end

  defp maybe_put_tool_config(meta, _state), do: meta

  @dialyzer {:nowarn_function, emit_iteration_stop: 5}
  defp emit_iteration_stop(iteration, result, ctx, updated_ctx, started_at) do
    duration_native = System.monotonic_time() - started_at

    status =
      case result do
        {:ok, _} -> :ok
        {:error, _} -> :error
        _ -> :unknown
      end

    measurements = %{duration: duration_native}

    metadata = %{
      agent: Map.get(ctx, :module) || Map.get(updated_ctx, :module),
      iteration: iteration,
      status: status,
      timestamp: DateTime.utc_now()
    }

    :telemetry.execute([:ash_agent, :iteration, :stop], measurements, metadata)
  end

  defp emit_stream_stop(span_context, metadata, started_at, last_chunk, status) do
    duration_native = System.monotonic_time() - started_at

    stop_meta =
      metadata
      |> Map.put(:telemetry_span_context, span_context)
      |> Map.put(:status, status)
      |> maybe_put_usage(last_chunk)
      |> maybe_put_result(last_chunk)
      |> Map.put(:response, last_chunk)

    :telemetry.execute([:ash_agent, :stream, :stop], %{duration: duration_native}, stop_meta)

    summary_meta =
      stop_meta
      |> Map.put(:kind, :stream)
      |> Map.put_new(:timestamp, DateTime.utc_now())

    :telemetry.execute([:ash_agent, :stream, :summary], %{}, summary_meta)
  end

  defp normalize_result({:ok, _} = ok), do: ok
  defp normalize_result({:error, _} = error), do: error
  defp normalize_result(other), do: {:error, other}

  defp maybe_put_result(metadata, nil), do: metadata
  defp maybe_put_result(metadata, result), do: Map.put(metadata, :result, result)

  defp maybe_put_usage(metadata, nil), do: metadata

  defp maybe_put_usage(metadata, chunk) do
    case Extension.response_usage(metadata.provider, chunk) do
      nil -> metadata
      usage -> Map.put(metadata, :usage, usage)
    end
  end

  defp telemetry_metadata(config, module, type) do
    %{
      agent: module,
      provider: config.provider,
      client: config.client,
      type: type,
      profile: config.profile
    }
  end

  defp build_single_turn_metadata(metadata, result, response, ctx) do
    base_metadata =
      metadata
      |> Map.put(:context, ctx)
      |> Map.put(:response, response)

    base_metadata =
      case Extension.response_usage(metadata.provider, response) do
        nil -> base_metadata
        usage -> Map.put(base_metadata, :usage, usage)
      end

    case result do
      {:ok, parsed} -> Map.put(base_metadata, :result, parsed)
      _ -> base_metadata
    end
  end

  defp execute_prepare_tool_results_hook(results, tool_calls, ctx, %LoopState{} = state) do
    if state.config.hooks do
      hook_context = %{
        agent: state.module,
        iteration: ctx.current_iteration,
        tool_calls: tool_calls,
        results: results,
        context: ctx,
        token_usage: state.config.context_module.get_cumulative_tokens(ctx)
      }

      case Extension.execute_hook(state.config.hooks, :prepare_tool_results, hook_context) do
        {:ok, updated_results} when is_list(updated_results) ->
          updated_results

        {:ok, ^hook_context} ->
          # Hook not implemented, Extension.execute_hook returned the context map as-is
          results

        {:error, reason} ->
          require Logger

          Logger.warning(
            "prepare_tool_results hook failed: #{inspect(reason)}, using original results"
          )

          :telemetry.execute(
            [:ash_agent, :hook, :error],
            %{},
            %{hook_name: :prepare_tool_results, error: reason}
          )

          results
      end
    else
      results
    end
  end

  defp execute_prepare_context_hook(ctx, %LoopState{} = state) do
    if state.config.hooks do
      hook_context = %{
        agent: state.module,
        context: ctx,
        token_usage: state.config.context_module.get_cumulative_tokens(ctx),
        iteration: ctx.current_iteration
      }

      case Extension.execute_hook(state.config.hooks, :prepare_context, hook_context) do
        {:ok, %Context{} = updated_ctx} ->
          updated_ctx

        {:ok, ^hook_context} ->
          # Hook not implemented, Extension.execute_hook returned the context map as-is
          ctx

        {:error, reason} ->
          require Logger

          Logger.warning(
            "prepare_context hook failed: #{inspect(reason)}, using original context"
          )

          :telemetry.execute(
            [:ash_agent, :hook, :error],
            %{},
            %{hook_name: :prepare_context, error: reason}
          )

          ctx
      end
    else
      ctx
    end
  end

  defp execute_prepare_messages_hook(messages, ctx, %LoopState{} = state) do
    if state.config.hooks do
      hook_context = %{
        agent: state.module,
        context: ctx,
        messages: messages,
        tools: state.tools,
        iteration: ctx.current_iteration
      }

      case Extension.execute_hook(state.config.hooks, :prepare_messages, hook_context) do
        {:ok, updated_messages} when is_list(updated_messages) ->
          updated_messages

        {:ok, ^hook_context} ->
          # Hook not implemented, Extension.execute_hook returned the context map as-is
          messages

        {:error, reason} ->
          require Logger

          Logger.warning(
            "prepare_messages hook failed: #{inspect(reason)}, using original messages"
          )

          :telemetry.execute(
            [:ash_agent, :hook, :error],
            %{},
            %{hook_name: :prepare_messages, error: reason}
          )

          messages
      end
    else
      messages
    end
  end

  defp execute_on_iteration_start_hook(ctx, %LoopState{} = state) do
    with :ok <- check_max_iterations(ctx, state),
         :ok <- check_token_budget(ctx, state) do
      execute_custom_iteration_start_hook(ctx, state)
    end
  end

  defp check_max_iterations(ctx, %LoopState{} = state) do
    if ctx.current_iteration > state.tool_config.max_iterations do
      {:error,
       Extension.llm_error(
         "Max iterations (#{state.tool_config.max_iterations}) exceeded",
         %{
           max: state.tool_config.max_iterations,
           current: ctx.current_iteration
         }
       )}
    else
      :ok
    end
  end

  defp execute_custom_iteration_start_hook(ctx, %LoopState{} = state) do
    if state.config.hooks do
      hook_context = %{
        agent: state.module,
        iteration_number: ctx.current_iteration,
        context: ctx,
        result: nil,
        token_usage: state.config.context_module.get_cumulative_tokens(ctx),
        max_iterations: state.tool_config.max_iterations,
        client: state.config.client
      }

      :telemetry.execute(
        [:ash_agent, :hook, :start],
        %{},
        %{hook_name: :on_iteration_start}
      )

      start_time = System.monotonic_time()
      result = Extension.execute_hook(state.config.hooks, :on_iteration_start, hook_context)
      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:ash_agent, :hook, :stop],
        %{duration: duration},
        %{hook_name: :on_iteration_start}
      )

      result
    else
      {:ok, ctx}
    end
  end

  defp check_token_budget(ctx, %LoopState{} = state) do
    budget = state.config.token_budget
    strategy = state.config.budget_strategy
    cumulative = state.config.context_module.get_cumulative_tokens(ctx)

    case Extension.check_token_limit(
           cumulative.total_tokens,
           state.config.client,
           nil,
           nil,
           budget,
           strategy
         ) do
      :ok ->
        :ok

      {:warn, limit, threshold} ->
        :telemetry.execute(
          [:ash_agent, :token_limit_warning],
          %{cumulative_tokens: cumulative.total_tokens},
          %{
            agent: state.module,
            limit: limit,
            threshold_percent: trunc(threshold * 100),
            cumulative_tokens: cumulative.total_tokens
          }
        )

        :ok

      {:error, :budget_exceeded} ->
        {:error,
         Extension.budget_error(
           "Token budget (#{budget}) exceeded",
           %{
             token_budget: budget,
             cumulative_tokens: cumulative.total_tokens,
             exceeded_by: cumulative.total_tokens - budget
           }
         )}
    end
  end

  defp execute_on_iteration_complete_hook(ctx, iteration_result, %LoopState{} = state) do
    # Check token limits (always enforced)
    cumulative = state.config.context_module.get_cumulative_tokens(ctx)

    case Extension.check_token_limit(cumulative.total_tokens, state.config.client) do
      :ok ->
        :ok

      {:warn, limit, threshold} ->
        :telemetry.execute(
          [:ash_agent, :token_limit_warning],
          %{cumulative_tokens: cumulative.total_tokens},
          %{
            agent: state.module,
            limit: limit,
            threshold_percent: trunc(threshold * 100),
            cumulative_tokens: cumulative.total_tokens
          }
        )
    end

    # Then call custom hook if configured
    if state.config.hooks do
      hook_context = %{
        agent: state.module,
        iteration_number: ctx.current_iteration,
        context: ctx,
        result: iteration_result,
        token_usage: cumulative,
        max_iterations: state.tool_config.max_iterations,
        client: state.config.client
      }

      :telemetry.execute(
        [:ash_agent, :hook, :start],
        %{},
        %{hook_name: :on_iteration_complete}
      )

      start_time = System.monotonic_time()
      result = Extension.execute_hook(state.config.hooks, :on_iteration_complete, hook_context)
      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:ash_agent, :hook, :stop],
        %{duration: duration},
        %{hook_name: :on_iteration_complete}
      )

      case result do
        {:error, reason} ->
          require Logger

          Logger.warning(
            "on_iteration_complete hook failed: #{inspect(reason)}, continuing iteration"
          )

          :telemetry.execute(
            [:ash_agent, :hook, :error],
            %{},
            %{hook_name: :on_iteration_complete, error: reason}
          )

        _ ->
          :ok
      end
    end

    :ok
  end
end
