defmodule SymphonyElixir.ExtensionHostFixtures do
  @moduledoc false

  @recipient :oxe11_extension_fixture_recipient

  def notify(message) do
    if recipient = Process.whereis(@recipient), do: send(recipient, message)
    :ok
  end

  def option(context, key, default \\ nil) do
    context
    |> Map.fetch!(:options)
    |> Map.get(key, default)
  end

  def action(context, key) do
    case option(context, key) do
      "raise" -> :raise
      "throw" -> :throw
      "exit" -> :exit
      _other -> nil
    end
  end
end

defmodule SymphonyElixir.ExtensionHostFixtures.Action do
  @moduledoc false

  def run(:raise, _result), do: raise("fixture adapter raised")
  def run(:throw, _result), do: throw(:fixture_adapter_threw)
  def run(:exit, _result), do: exit(:fixture_adapter_exited)
  def run(_action, result), do: result
end

defmodule SymphonyElixir.ExtensionHostFixtures.DispatchAdmission do
  @moduledoc false

  @behaviour SymphonyElixir.Extensions.DispatchAdmission

  alias SymphonyElixir.ExtensionHostFixtures.Action
  alias SymphonyElixir.Extensions.ExtensionFailure

  @impl true
  def evaluate(issue, context) do
    :ok = SymphonyElixir.ExtensionHostFixtures.notify({:dispatch_admission, issue, context})

    result =
      case SymphonyElixir.ExtensionHostFixtures.option(context, "admission_result") do
        "admit" -> {:admit, %{issue_id: issue.id}}
        "error" -> {:error, %ExtensionFailure{code: :fixture_failure, interface: :dispatch_admission}}
        "malformed" -> :malformed
        _other -> :kernel_default
      end

    Action.run(
      SymphonyElixir.ExtensionHostFixtures.action(context, "admission_action"),
      result
    )
  end
end

defmodule SymphonyElixir.ExtensionHostFixtures.DeliveryController do
  @moduledoc false

  @behaviour SymphonyElixir.Extensions.DeliveryController

  alias SymphonyElixir.ExtensionHostFixtures.Action
  alias SymphonyElixir.Extensions.ControllerFailure

  @impl true
  def handle(event, context) do
    :ok = SymphonyElixir.ExtensionHostFixtures.notify({:delivery_controller, event, context})

    result =
      case SymphonyElixir.ExtensionHostFixtures.option(context, "delivery_result") do
        "continue" ->
          {:ok, :continue, [%{type: :continued}]}

        "error" ->
          {:error, %ControllerFailure{code: :fixture_failure, interface: :delivery_controller}, [%{type: :evidence}]}

        "malformed" ->
          :malformed

        _other ->
          :kernel_default
      end

    Action.run(
      SymphonyElixir.ExtensionHostFixtures.action(context, "delivery_action"),
      result
    )
  end
end

defmodule SymphonyElixir.ExtensionHostFixtures.CommandAuthorization do
  @moduledoc false

  alias SymphonyElixir.ExtensionHostFixtures.Action
  alias SymphonyElixir.Extensions.ExtensionFailure

  @behaviour SymphonyElixir.Extensions.CommandAuthorization

  @impl true
  def authorize(intent, context) do
    :ok = SymphonyElixir.ExtensionHostFixtures.notify({:command_authorization, intent, context})

    context
    |> SymphonyElixir.ExtensionHostFixtures.option("authorization_action")
    |> fixture_action()
    |> Action.run(authorization_result(context))
  end

  defp authorization_result(context) do
    case SymphonyElixir.ExtensionHostFixtures.option(context, "authorization_result") do
      "allow" ->
        :allow

      "allow_once" ->
        {:allow_once, %{lease: "one"}}

      "error" ->
        {:error,
         %ExtensionFailure{
           code: :fixture_failure,
           interface: :command_authorization
         }}

      "malformed" ->
        :malformed

      _other ->
        :kernel_default
    end
  end

  defp fixture_action("raise"), do: :raise
  defp fixture_action("throw"), do: :throw
  defp fixture_action("exit"), do: :exit
  defp fixture_action(_other), do: nil
end

defmodule SymphonyElixir.ExtensionHostFixtures.DeliveryObserver do
  @moduledoc false

  alias SymphonyElixir.ExtensionHostFixtures.Action

  def record(event) do
    send(event.test_pid, {:delivery_observer, event})
    Action.run(Map.get(event, :action), Map.get(event, :result, :ok))
  end
end

defmodule SymphonyElixir.ExtensionHostFixtures.RaisingObserver do
  @moduledoc false

  def record(_event), do: raise("observer token=do-not-log")
end

defmodule SymphonyElixir.ExtensionLifecycleFixtures do
  @moduledoc false

  @recipient :oxe12_extension_fixture_recipient

  def notify(message) do
    if recipient = Process.whereis(@recipient), do: send(recipient, message)
    :ok
  end

  def option(context, key) when is_map(context) and is_binary(key) do
    context
    |> Map.get(:options, %{})
    |> Map.get(key)
  end

  def option(_context, _key), do: nil
end

defmodule SymphonyElixir.ExtensionLifecycleFixtures.DispatchAdmission do
  @moduledoc false

  @behaviour SymphonyElixir.Extensions.DispatchAdmission

  alias SymphonyElixir.ExtensionLifecycleFixtures
  alias SymphonyElixir.Extensions.ExtensionFailure

  @impl true
  def evaluate(issue, context) do
    :ok = ExtensionLifecycleFixtures.notify({:oxe12_admission, issue, context})

    case ExtensionLifecycleFixtures.option(context, "admission_result") do
      "admit" ->
        {:admit, %{class: :fixture_admission}}

      "reject" ->
        {:reject, %{class: :fixture_rejection}}

      "error" ->
        {:error,
         %ExtensionFailure{
           code: :fixture_admission_failed,
           interface: :dispatch_admission,
           reason: %{secret: "adapter-reason-do-not-log"}
         }}

      _other ->
        :kernel_default
    end
  end
end

defmodule SymphonyElixir.ExtensionLifecycleFixtures.DeliveryController do
  @moduledoc false

  @behaviour SymphonyElixir.Extensions.DeliveryController

  alias SymphonyElixir.ExtensionLifecycleFixtures
  alias SymphonyElixir.Extensions.ControllerFailure

  @impl true
  def handle(event, context) do
    :ok = ExtensionLifecycleFixtures.notify({:oxe12_delivery, event, context})

    case ExtensionLifecycleFixtures.option(context, "delivery_result") do
      "decision" ->
        {:ok, :fixture_park, [%{type: :fixture_evidence}]}

      "error" ->
        {:error,
         %ControllerFailure{
           code: :fixture_delivery_stopped,
           interface: :delivery_controller,
           reason: :fixture_requested
         }, []}

      _other ->
        :kernel_default
    end
  end
end

defmodule SymphonyElixir.ExtensionTurnFixtures do
  @moduledoc false

  @recipient :oxe13_extension_fixture_recipient

  def notify(message) do
    if recipient = Process.whereis(@recipient), do: send(recipient, message)
    :ok
  end

  def option(value, key) when is_map(value) and is_binary(key) do
    value
    |> Map.get(:options, %{})
    |> Map.get(key)
  end

  def option(_value, _key), do: nil
end

defmodule SymphonyElixir.ExtensionTurnFixtures.CommandAuthorization do
  @moduledoc false

  @behaviour SymphonyElixir.Extensions.CommandAuthorization

  alias SymphonyElixir.ExtensionHostFixtures.Action
  alias SymphonyElixir.Extensions.ExtensionFailure
  alias SymphonyElixir.ExtensionTurnFixtures

  @impl true
  def authorize(intent, context) do
    :ok = ExtensionTurnFixtures.notify({:oxe13_authorization, self(), intent, context})
    :ok = wait_if_paused(context)

    context
    |> authorization_action()
    |> Action.run(authorization_result(context))
  end

  defp wait_if_paused(context) do
    if ExtensionTurnFixtures.option(context, "authorization_pause") do
      receive do
        :oxe13_continue -> :ok
      after
        1_000 -> raise "OXE-1.3 authorization fixture timed out"
      end
    else
      :ok
    end
  end

  defp authorization_result(context) do
    case ExtensionTurnFixtures.option(context, "authorization_result") do
      "allow" ->
        :allow

      "allow_once" ->
        {:allow_once, %{class: :fixture_lease}}

      "deny" ->
        {:deny, %{code: :fixture_denied}}

      "error" ->
        {:error,
         %ExtensionFailure{
           code: :fixture_authorization_failed,
           interface: :command_authorization,
           reason: %{secret: "authorization-reason-do-not-log"}
         }}

      "malformed" ->
        :malformed

      _other ->
        :kernel_default
    end
  end

  defp authorization_action(context) do
    case ExtensionTurnFixtures.option(context, "authorization_action") do
      "raise" -> :raise
      "throw" -> :throw
      "exit" -> :exit
      _other -> nil
    end
  end
end

defmodule SymphonyElixir.ExtensionObserverFixtures do
  @moduledoc false

  @recipient :oxe13a_extension_observer_fixture_recipient

  def notify(message) do
    if recipient = Process.whereis(@recipient), do: send(recipient, message)
    :ok
  end
end

defmodule SymphonyElixir.ExtensionObserverFixtures.Observer do
  @moduledoc false

  @behaviour SymphonyElixir.Extensions.DeliveryObserver

  @impl true
  def record(envelope) do
    SymphonyElixir.ExtensionObserverFixtures.notify({:oxe13a_observer, envelope})
  end
end

defmodule SymphonyElixir.ExtensionObserverFixtures.HangingObserver do
  @moduledoc false

  @behaviour SymphonyElixir.Extensions.DeliveryObserver

  @impl true
  def record(envelope) do
    SymphonyElixir.ExtensionObserverFixtures.notify({:oxe13a_observer_hanging, self(), envelope})

    receive do
      :oxe13a_continue -> :ok
    end
  end
end

defmodule SymphonyElixir.ExtensionObserverFixtures.ErrorObserver do
  @moduledoc false

  @behaviour SymphonyElixir.Extensions.DeliveryObserver

  alias SymphonyElixir.Extensions.ObserverFailure

  @impl true
  def record(_envelope) do
    {:error,
     %ObserverFailure{
       code: :fixture_observer_failed,
       interface: :delivery_observer,
       reason: %{secret: "observer-error-reason-do-not-log"}
     }}
  end
end

defmodule SymphonyElixir.ExtensionObserverFixtures.MalformedObserver do
  @moduledoc false

  @behaviour SymphonyElixir.Extensions.DeliveryObserver

  @impl true
  def record(_envelope), do: {:unexpected, "observer-malformed-do-not-log"}
end

defmodule SymphonyElixir.ExtensionObserverFixtures.WrongInterfaceObserver do
  @moduledoc false

  @behaviour SymphonyElixir.Extensions.DeliveryObserver

  alias SymphonyElixir.Extensions.ObserverFailure

  @impl true
  def record(_envelope) do
    {:error,
     %ObserverFailure{
       code: :fixture_wrong_interface,
       interface: :command_authorization,
       reason: %{secret: "observer-wrong-interface-do-not-log"}
     }}
  end
end

defmodule SymphonyElixir.ExtensionObserverFixtures.ThrowingObserver do
  @moduledoc false

  @behaviour SymphonyElixir.Extensions.DeliveryObserver

  @impl true
  def record(_envelope), do: throw(:"observer-throw-reason-do-not-log")
end

defmodule SymphonyElixir.ExtensionObserverFixtures.ExitingObserver do
  @moduledoc false

  @behaviour SymphonyElixir.Extensions.DeliveryObserver

  @impl true
  def record(_envelope), do: exit(:"observer-exit-reason-do-not-log")
end

defmodule SymphonyElixir.ExtensionObserverFixtures.KillingObserver do
  @moduledoc false

  @behaviour SymphonyElixir.Extensions.DeliveryObserver

  @impl true
  def record(_envelope), do: exit(:kill)
end
