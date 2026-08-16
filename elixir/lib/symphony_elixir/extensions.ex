defmodule SymphonyElixir.Extensions do
  @moduledoc """
  The sole kernel-facing facade for extension decisions and observation.
  """

  require Logger

  alias SymphonyElixir.ExtensionRegistry
  alias SymphonyElixir.Extensions.AdmissionContext
  alias SymphonyElixir.Extensions.CommandAuthorization
  alias SymphonyElixir.Extensions.ControllerFailure
  alias SymphonyElixir.Extensions.DeliveryContext
  alias SymphonyElixir.Extensions.DeliveryController
  alias SymphonyElixir.Extensions.DeliveryEvent
  alias SymphonyElixir.Extensions.DispatchAdmission
  alias SymphonyElixir.Extensions.ExtensionFailure
  alias SymphonyElixir.Extensions.ObserverFailure
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow

  @type attempt :: non_neg_integer() | nil
  @type worker_host :: String.t() | nil
  @type workspace_ready_facts :: {Issue.t(), Path.t(), worker_host(), attempt()}

  @spec evaluate_admission(Issue.t(), attempt()) :: DispatchAdmission.result()
  def evaluate_admission(%Issue{} = issue, attempt) when is_nil(attempt) or is_integer(attempt) do
    with {:ok, registry, options} <- lock_registry(:dispatch_admission) do
      context = %AdmissionContext{
        attempt: normalize_attempt(attempt),
        registry_revision: registry.revision,
        options: options
      }

      registry.dispatch_admission
      |> safe_call(:evaluate, [issue, context])
      |> admission_result(registry)
    end
  end

  def evaluate_admission(%Issue{}, _attempt) do
    {:error,
     extension_failure(
       :invalid_kernel_input,
       :dispatch_admission,
       nil,
       nil,
       :attempt_invalid
     )}
  end

  @spec handle_delivery(:workspace_ready, workspace_ready_facts()) :: DeliveryController.result()
  def handle_delivery(
        :workspace_ready,
        {%Issue{} = issue, workspace, worker_host, attempt}
      )
      when is_binary(workspace) and (is_nil(worker_host) or is_binary(worker_host)) and
             (is_nil(attempt) or is_integer(attempt)) do
    case lock_registry(:delivery_controller) do
      {:ok, registry, options} ->
        event = %DeliveryEvent{type: :workspace_ready}

        context = %DeliveryContext{
          issue: issue,
          workspace: workspace,
          worker_host: worker_host,
          attempt: normalize_attempt(attempt),
          registry_revision: registry.revision,
          options: options
        }

        registry.delivery_controller
        |> safe_call(:handle, [event, context])
        |> delivery_result(registry)

      {:error, failure} ->
        {:error, controller_failure(failure), []}
    end
  end

  def handle_delivery(_event, _facts) do
    {:error,
     controller_failure(
       :invalid_kernel_input,
       nil,
       nil,
       :workspace_ready_facts_invalid
     ), []}
  end

  @spec authorize(term(), term()) :: CommandAuthorization.result()
  def authorize(intent, context) do
    with {:ok, registry, _options} <- lock_registry(:command_authorization) do
      registry.command_authorization
      |> safe_call(:authorize, [intent, context])
      |> authorization_result(registry)
    end
  end

  @spec record(term()) :: :ok
  def record(event) do
    case ExtensionRegistry.current() do
      {:ok, registry} ->
        Enum.each(registry.observers, &record_observer(&1, event, registry))

      {:error, _failure} ->
        Logger.error("delivery observer failed class=registry_unavailable")
    end

    :ok
  end

  defp lock_registry(interface) do
    case Workflow.current() do
      {:ok, %{config: config}} ->
        case ExtensionRegistry.lock(config) do
          {:ok, registry, options} -> {:ok, registry, options}
          {:error, %ExtensionFailure{} = failure} -> {:error, failure}
        end

      {:error, _reason} ->
        {:error,
         extension_failure(
           :extension_configuration_unavailable,
           interface,
           nil,
           nil,
           :workflow_unavailable
         )}
    end
  end

  defp admission_result({:ok, result}, _registry)
       when result == :kernel_default or
              (is_tuple(result) and tuple_size(result) == 2 and
                 elem(result, 0) in [:admit, :reject]),
       do: result

  defp admission_result(
         {:ok, {:error, %ExtensionFailure{interface: :dispatch_admission} = failure}},
         registry
       ) do
    {:error, stamp_failure(failure, registry.dispatch_admission, registry.revision)}
  end

  defp admission_result({:ok, _malformed}, registry) do
    {:error,
     extension_failure(
       :invalid_adapter_return,
       :dispatch_admission,
       registry.dispatch_admission,
       registry.revision,
       :malformed_return
     )}
  end

  defp admission_result({:error, class}, registry) do
    {:error,
     extension_failure(
       :adapter_failure,
       :dispatch_admission,
       registry.dispatch_admission,
       registry.revision,
       class
     )}
  end

  defp delivery_result({:ok, :kernel_default}, _registry), do: :kernel_default

  defp delivery_result({:ok, {:ok, _decision, events} = result}, _registry)
       when is_list(events),
       do: result

  defp delivery_result(
         {:ok, {:error, %ControllerFailure{interface: :delivery_controller} = failure, events}},
         registry
       )
       when is_list(events) do
    {:error, stamp_failure(failure, registry.delivery_controller, registry.revision), events}
  end

  defp delivery_result({:ok, _malformed}, registry) do
    {:error,
     controller_failure(
       :invalid_adapter_return,
       registry.delivery_controller,
       registry.revision,
       :malformed_return
     ), []}
  end

  defp delivery_result({:error, class}, registry) do
    {:error,
     controller_failure(
       :adapter_failure,
       registry.delivery_controller,
       registry.revision,
       class
     ), []}
  end

  defp authorization_result({:ok, result}, _registry)
       when result in [:kernel_default, :allow],
       do: result

  defp authorization_result({:ok, result}, _registry)
       when is_tuple(result) and tuple_size(result) == 2 and
              elem(result, 0) in [:allow_once, :deny],
       do: result

  defp authorization_result(
         {:ok, {:error, %ExtensionFailure{interface: :command_authorization} = failure}},
         registry
       ) do
    {:error, stamp_failure(failure, registry.command_authorization, registry.revision)}
  end

  defp authorization_result({:ok, _malformed}, registry) do
    {:error,
     extension_failure(
       :invalid_adapter_return,
       :command_authorization,
       registry.command_authorization,
       registry.revision,
       :malformed_return
     )}
  end

  defp authorization_result({:error, class}, registry) do
    {:error,
     extension_failure(
       :adapter_failure,
       :command_authorization,
       registry.command_authorization,
       registry.revision,
       class
     )}
  end

  defp record_observer(adapter, event, registry) do
    case safe_call(adapter, :record, [event]) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, %ObserverFailure{}}} ->
        log_observer_failure(adapter, registry, :adapter_error)

      {:ok, _malformed} ->
        log_observer_failure(adapter, registry, :invalid_adapter_return)

      {:error, class} ->
        log_observer_failure(adapter, registry, class)
    end
  end

  defp log_observer_failure(adapter, registry, class) do
    Logger.error(
      "delivery observer failed interface=delivery_observer adapter=#{inspect(adapter)} " <>
        "registry_revision=#{registry.revision} class=#{class}"
    )
  end

  defp safe_call(adapter, function, arguments) do
    {:ok, apply(adapter, function, arguments)}
  rescue
    _exception -> {:error, :raise}
  catch
    :throw, _reason -> {:error, :throw}
    :exit, _reason -> {:error, :exit}
  end

  defp extension_failure(code, interface, adapter, revision, reason) do
    %ExtensionFailure{
      code: code,
      interface: interface,
      adapter: adapter,
      registry_revision: revision,
      reason: reason
    }
  end

  defp stamp_failure(failure, adapter, revision) do
    %{failure | adapter: adapter, registry_revision: revision}
  end

  defp normalize_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_attempt(_attempt), do: 0

  defp controller_failure(%ExtensionFailure{} = failure) do
    controller_failure(
      failure.code,
      failure.adapter,
      failure.registry_revision,
      failure.reason
    )
  end

  defp controller_failure(code, adapter, revision, reason) do
    %ControllerFailure{
      code: code,
      interface: :delivery_controller,
      adapter: adapter,
      registry_revision: revision,
      reason: reason
    }
  end
end
