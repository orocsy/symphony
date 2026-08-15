defmodule SymphonyElixir.ExtensionHostFixtures.Action do
  @moduledoc false

  def run(:raise, _result), do: raise("fixture adapter raised")
  def run(:throw, _result), do: throw(:fixture_adapter_threw)
  def run(:exit, _result), do: exit(:fixture_adapter_exited)
  def run(_action, result), do: result
end

defmodule SymphonyElixir.ExtensionHostFixtures.DispatchAdmission do
  @moduledoc false

  alias SymphonyElixir.ExtensionHostFixtures.Action

  def evaluate(issue, context) do
    send(context.test_pid, {:dispatch_admission, issue, context})
    Action.run(Map.get(context, :action), Map.fetch!(context, :result))
  end
end

defmodule SymphonyElixir.ExtensionHostFixtures.DeliveryController do
  @moduledoc false

  alias SymphonyElixir.ExtensionHostFixtures.Action

  def handle(event, context) do
    send(context.test_pid, {:delivery_controller, event, context})
    Action.run(Map.get(context, :action), Map.fetch!(context, :result))
  end
end

defmodule SymphonyElixir.ExtensionHostFixtures.CommandAuthorization do
  @moduledoc false

  alias SymphonyElixir.ExtensionHostFixtures.Action

  def authorize(intent, context) do
    send(context.test_pid, {:command_authorization, intent, context})
    Action.run(Map.get(context, :action), Map.fetch!(context, :result))
  end
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

  @impl true
  def evaluate(issue, context) do
    :ok = ExtensionLifecycleFixtures.notify({:oxe12_admission, issue, context})

    case ExtensionLifecycleFixtures.option(context, "admission_result") do
      "reject" -> {:reject, %{class: :fixture_rejection}}
      _other -> :kernel_default
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
