defmodule SymphonyElixir.ExtensionsHostTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ExtensionRegistry
  alias SymphonyElixir.Extensions

  @production_modules [
    SymphonyElixir.Extensions,
    SymphonyElixir.ExtensionRegistry,
    SymphonyElixir.Extensions.DispatchAdmission,
    SymphonyElixir.Extensions.DeliveryController,
    SymphonyElixir.Extensions.CommandAuthorization,
    SymphonyElixir.Extensions.DeliveryObserver,
    SymphonyElixir.Extensions.Noop.DispatchAdmission,
    SymphonyElixir.Extensions.Noop.DeliveryController,
    SymphonyElixir.Extensions.Noop.CommandAuthorization,
    SymphonyElixir.Extensions.Noop.DeliveryObserver
  ]

  setup do
    reset_registry_if_available()
    on_exit(&reset_registry_if_available/0)
  end

  test "routes every facade operation through the locked registry" do
    install_extensions!("fixture", "fixture", "fixture", ["fixture"])
    issue = %Issue{id: "issue-1", identifier: "OXE-1", state: "Todo"}
    event = %{type: :workspace_ready, test_pid: self()}
    intent = %{kind: :shell, command: "git status"}

    admission_context = %{test_pid: self(), result: :kernel_default}
    delivery_context = %{test_pid: self(), result: :kernel_default}
    turn_context = %{test_pid: self(), result: :allow}

    assert :kernel_default == call(:evaluate_admission, [issue, admission_context])
    assert_receive {:dispatch_admission, ^issue, ^admission_context}

    assert :kernel_default == call(:handle_delivery, [event, delivery_context])
    assert_receive {:delivery_controller, ^event, ^delivery_context}

    assert :allow == call(:authorize, [intent, turn_context])
    assert_receive {:command_authorization, ^intent, ^turn_context}

    assert :ok == call(:record, [event])
    assert_receive {:delivery_observer, ^event}
  end

  test "returns kernel_default through every production no-op decision interface" do
    issue = %Issue{id: "issue-2", identifier: "OXE-2", state: "Todo"}

    assert :kernel_default == call(:evaluate_admission, [issue, %{}])
    assert :kernel_default == call(:handle_delivery, [%{type: :workspace_ready}, %{}])
    assert :kernel_default == call(:authorize, [%{kind: :shell}, %{}])
    assert :ok == call(:record, [%{type: :notification}])
  end

  test "rejects malformed adapter returns instead of falling back" do
    install_extensions!("fixture", "fixture", "fixture", [])
    issue = %Issue{id: "issue-3", identifier: "OXE-3", state: "Todo"}

    assert {:error, admission_failure} =
             call(:evaluate_admission, [issue, %{test_pid: self(), result: :malformed}])

    assert admission_failure.code == :invalid_adapter_return
    assert admission_failure.interface == :dispatch_admission

    assert {:error, delivery_failure, []} =
             call(:handle_delivery, [
               %{type: :workspace_ready},
               %{test_pid: self(), result: :malformed}
             ])

    assert delivery_failure.code == :invalid_adapter_return
    assert delivery_failure.interface == :delivery_controller

    assert {:error, authorization_failure} =
             call(:authorize, [
               %{kind: :shell},
               %{test_pid: self(), result: :malformed}
             ])

    assert authorization_failure.code == :invalid_adapter_return
    assert authorization_failure.interface == :command_authorization
  end

  test "normalizes adapter raise, throw, and exit without neutral fallback" do
    install_extensions!("fixture", "fixture", "fixture", [])
    issue = %Issue{id: "issue-4", identifier: "OXE-4", state: "Todo"}

    for action <- [:raise, :throw, :exit] do
      assert {:error, failure} =
               call(:evaluate_admission, [
                 issue,
                 %{test_pid: self(), action: action, result: :kernel_default}
               ])

      assert failure.code == :adapter_failure
      assert failure.interface == :dispatch_admission
      refute failure == :kernel_default
    end
  end

  test "isolates observer failure and continues observer fan-out" do
    install_extensions!("fixture", "fixture", "fixture", ["raising", "fixture"])
    event = %{type: :notification, test_pid: self(), secret: "do-not-log"}

    log = capture_log(fn -> assert :ok == call(:record, [event]) end)

    assert_receive {:delivery_observer, ^event}
    assert log =~ "delivery observer failed"
    refute log =~ "do-not-log"
  end

  test "keeps Orocsy dependencies outside the generic host tree" do
    for module <- @production_modules do
      assert Code.ensure_loaded?(module)
      source = module.module_info(:compile) |> Keyword.fetch!(:source) |> to_string()
      refute File.read!(source) =~ "Orocsy"
    end
  end

  defp call(function, arguments), do: apply(Extensions, function, arguments)

  defp install_extensions!(admission, delivery, authorization, observers) do
    path = Workflow.workflow_file_path()
    source = File.read!(path)

    stanza = """
    extensions:
      dispatch_admission: #{admission}
      delivery_controller: #{delivery}
      command_authorization: #{authorization}
      observers: [#{Enum.join(observers, ", ")}]
      options:
        marker: fixture
    """

    File.write!(path, String.replace(source, "---\n", "---\n#{stanza}", global: false))
    assert :ok = WorkflowStore.force_reload()
  end

  defp reset_registry_if_available do
    if Code.ensure_loaded?(ExtensionRegistry) and
         function_exported?(ExtensionRegistry, :reset_for_test, 0) do
      apply(ExtensionRegistry, :reset_for_test, [])
    else
      :ok
    end
  end
end
