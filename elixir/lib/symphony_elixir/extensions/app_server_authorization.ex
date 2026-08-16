defmodule SymphonyElixir.Extensions.AppServerAuthorization do
  @moduledoc false

  require Logger

  alias SymphonyElixir.Extensions
  alias SymphonyElixir.Extensions.ExtensionFailure
  alias SymphonyElixir.Extensions.TurnContext

  @methods [
    "item/commandExecution/requestApproval",
    "item/fileChange/requestApproval",
    "execCommandApproval",
    "applyPatchApproval",
    "item/tool/call",
    "item/tool/requestUserInput"
  ]

  @type subscriber :: (map() -> term())
  @type tool_executor :: (String.t() | nil, term() -> map())
  @type request_facts ::
          {port(), String.t(), map(), String.t(), subscriber(), map(), tool_executor(), boolean()}

  @type result ::
          :kernel_default
          | :approved
          | :approval_required
          | :input_required
          | {:unsafe_input_required, map()}
          | :unhandled

  @spec prepare_turn(term(), (-> term()), (-> :ok)) ::
          {:ok, String.t(), TurnContext.t()} | {:error, term()}
  def prepare_turn({_issue, _workspace, _worker_host, thread_id} = facts, start_turn, invalidate)
      when is_function(start_turn, 0) and is_function(invalidate, 0) do
    case Extensions.capture_turn(facts) do
      {:ok, seed} -> prepare_bound_turn(seed, start_turn, invalidate)
      {:error, %ExtensionFailure{} = failure} -> capture_failure(failure, thread_id, invalidate)
    end
  end

  @spec handle(request_facts(), TurnContext.t(), function()) :: result()
  def handle(
        {port, method, payload, _payload_string, on_message, metadata, _tool_executor, _auto_approve_requests} = facts,
        %TurnContext{} = context,
        fallback
      )
      when is_port(port) and method in @methods and is_map(payload) and
             is_function(on_message, 1) and is_map(metadata) and is_function(fallback, 8) do
    case Extensions.authorize({method, payload}, context) do
      :kernel_default ->
        apply(fallback, Tuple.to_list(facts))

      result ->
        handle_result(port, method, payload, on_message, metadata, result)
    end
  end

  def handle(facts, _context, fallback) when is_tuple(facts) and is_function(fallback, 8),
    do: apply(fallback, Tuple.to_list(facts))

  defp prepare_bound_turn(seed, start_turn, invalidate) do
    case start_turn.() do
      {:ok, turn_id} -> bind_started_turn(seed, turn_id, invalidate)
      other -> other
    end
  end

  defp bind_started_turn(seed, turn_id, invalidate) do
    case Extensions.bind_turn(seed, turn_id) do
      {:ok, context} ->
        {:ok, turn_id, context}

      {:error, %ExtensionFailure{} = failure} ->
        invalidate.()

        Logger.error("extension turn binding failed code=#{failure.code} interface=command_authorization")

        {:error, {:extension_turn_binding_failed, failure.code, :command_authorization}}
    end
  end

  defp capture_failure(failure, thread_id, invalidate) do
    if not (is_binary(thread_id) and thread_id != ""), do: invalidate.()

    Logger.error("extension turn context failed code=#{failure.code} interface=command_authorization")

    {:error, {:extension_turn_context_failed, failure.code, :command_authorization}}
  end

  defp handle_result(port, method, payload, on_message, metadata, result) do
    request_id = Map.get(payload, "id", :invalid)

    case classify(result, method, request_id) do
      :unsafe_input ->
        emit_event(
          on_message,
          :authorization_invalid,
          :command_intent_invalid,
          :invalid,
          method,
          metadata
        )

        close_port(port)

        {:unsafe_input_required, %{code: :command_intent_invalid, interface: :command_authorization}}

      :allow ->
        send_response(port, method, request_id, payload, :allow)
        emit_allow(on_message, method, metadata)
        :approved

      :deny ->
        send_response(port, method, request_id, payload, :deny)

        emit_event(
          on_message,
          :authorization_denied,
          :extension_authorization_denied,
          request_id,
          method,
          metadata
        )

        :approved

      :input_required ->
        :input_required

      :invalid ->
        send_response(port, method, request_id, payload, :invalid)

        emit_event(
          on_message,
          :authorization_invalid,
          :command_intent_invalid,
          request_id,
          method,
          metadata
        )

        :approved

      :error ->
        send_response(port, method, request_id, payload, :error)

        emit_event(
          on_message,
          :authorization_failed,
          :extension_authorization_failed,
          request_id,
          method,
          metadata
        )

        :approved
    end
  end

  defp classify(_result, _method, request_id)
       when not is_binary(request_id) and not is_integer(request_id),
       do: :unsafe_input

  defp classify(:allow, _method, _request_id), do: :allow
  defp classify({:allow_once, _lease}, _method, _request_id), do: :allow
  defp classify({:deny, _reason}, _method, _request_id), do: :deny

  defp classify(
         {:error,
          %ExtensionFailure{
            code: :command_intent_invalid,
            reason: reason
          }},
         "item/tool/requestUserInput",
         _request_id
       )
       when reason != :turn_correlation_mismatch,
       do: :input_required

  defp classify(
         {:error, %ExtensionFailure{code: :command_intent_invalid}},
         _method,
         _request_id
       ),
       do: :invalid

  defp classify(_result, _method, _request_id), do: :error

  defp send_response(port, method, request_id, _payload, outcome)
       when method in ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"] do
    decision = if outcome == :allow, do: "accept", else: "decline"
    send_message(port, %{"id" => request_id, "result" => %{"decision" => decision}})
  end

  defp send_response(port, method, request_id, _payload, outcome)
       when method in ["execCommandApproval", "applyPatchApproval"] do
    decision = if outcome == :allow, do: "approved", else: "denied"
    send_message(port, %{"id" => request_id, "result" => %{"decision" => decision}})
  end

  defp send_response(port, "item/tool/requestUserInput", request_id, payload, outcome) do
    label = if outcome == :allow, do: "Approve Once", else: "Deny"

    answers =
      payload
      |> get_in(["params", "questions"])
      |> tool_answers(label)

    send_message(port, %{"id" => request_id, "result" => %{"answers" => answers}})
  end

  defp send_response(port, "item/tool/call", request_id, _payload, outcome) do
    output =
      case outcome do
        :deny -> "extension authorization denied"
        _other -> "extension authorization failed"
      end

    send_message(port, %{
      "id" => request_id,
      "result" => %{
        "success" => false,
        "output" => output,
        "contentItems" => [%{"type" => "inputText", "text" => output}]
      }
    })
  end

  defp tool_answers(questions, label) when is_list(questions) do
    Map.new(questions, fn %{"id" => question_id} ->
      {question_id, %{"answers" => [label]}}
    end)
  end

  defp emit_allow(on_message, method, metadata) do
    emit(on_message, :approval_auto_approved, %{decision: allow_decision(method)}, metadata)
  end

  defp allow_decision(method)
       when method in ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"],
       do: "accept"

  defp allow_decision(method) when method in ["execCommandApproval", "applyPatchApproval"],
    do: "approved"

  defp allow_decision("item/tool/requestUserInput"), do: "Approve Once"

  defp emit_event(on_message, event, code, request_id, method, metadata) do
    emit(
      on_message,
      event,
      %{
        code: code,
        interface: :command_authorization,
        method: method,
        request_id: request_id
      },
      metadata
    )
  end

  defp emit(on_message, event, details, metadata) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp send_message(port, message) do
    Port.command(port, Jason.encode!(message) <> "\n")
  end

  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
