defmodule SymphonyElixir.ExtensionsHostTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ExtensionRegistry
  alias SymphonyElixir.Extensions
  alias SymphonyElixir.Extensions.ControllerFailure
  alias SymphonyElixir.Extensions.ExtensionFailure
  alias SymphonyElixir.Extensions.ObserverFailure

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

  test "lazily locks valid configuration from either direct decision entry point" do
    assert :kernel_default == call(:handle_delivery, [%{type: :workspace_ready}, %{}])

    reset_registry_if_available()

    assert :kernel_default == call(:authorize, [%{kind: :shell}, %{}])
    assert :ok == call(:record, [%{type: :notification}])
  end

  test "accepts valid typed decisions and stamps adapter failures at the facade" do
    install_extensions!("fixture", "fixture", "fixture", [])
    issue = %Issue{id: "issue-typed", identifier: "OXE-TYPED", state: "Todo"}

    assert {:admit, %{issue_id: "issue-typed"}} =
             call(:evaluate_admission, [
               issue,
               %{test_pid: self(), result: {:admit, %{issue_id: "issue-typed"}}}
             ])

    assert {:ok, :continue, [%{type: :continued}]} =
             call(:handle_delivery, [
               %{type: :workspace_ready},
               %{test_pid: self(), result: {:ok, :continue, [%{type: :continued}]}}
             ])

    assert {:allow_once, %{lease: "one"}} =
             call(:authorize, [
               %{kind: :shell},
               %{test_pid: self(), result: {:allow_once, %{lease: "one"}}}
             ])

    admission_failure = %ExtensionFailure{code: :fixture_failure, interface: :dispatch_admission}

    assert {:error, stamped_admission} =
             call(:evaluate_admission, [
               issue,
               %{test_pid: self(), result: {:error, admission_failure}}
             ])

    assert stamped_admission.adapter == SymphonyElixir.ExtensionHostFixtures.DispatchAdmission
    assert String.starts_with?(stamped_admission.registry_revision, "sha256:")

    delivery_failure = %ControllerFailure{code: :fixture_failure, interface: :delivery_controller}

    assert {:error, stamped_delivery, [%{type: :evidence}]} =
             call(:handle_delivery, [
               %{type: :workspace_ready},
               %{
                 test_pid: self(),
                 result: {:error, delivery_failure, [%{type: :evidence}]}
               }
             ])

    assert stamped_delivery.adapter == SymphonyElixir.ExtensionHostFixtures.DeliveryController
    assert String.starts_with?(stamped_delivery.registry_revision, "sha256:")

    authorization_failure = %ExtensionFailure{
      code: :fixture_failure,
      interface: :command_authorization
    }

    assert {:error, stamped_authorization} =
             call(:authorize, [
               %{kind: :shell},
               %{test_pid: self(), result: {:error, authorization_failure}}
             ])

    assert stamped_authorization.adapter ==
             SymphonyElixir.ExtensionHostFixtures.CommandAuthorization

    assert String.starts_with?(stamped_authorization.registry_revision, "sha256:")
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

  test "rejects invalid registry configuration before invoking admission" do
    install_extensions!("not-installed", "noop", "noop", ["noop"])
    issue = %Issue{id: "issue-invalid", identifier: "OXE-INVALID", state: "Todo"}

    assert {:error, failure} = call(:evaluate_admission, [issue, %{}])
    assert failure.code == :unknown_adapter
    assert failure.interface == :dispatch_admission
    assert failure.adapter == nil
  end

  test "normalizes delivery and authorization adapter failures" do
    install_extensions!("fixture", "fixture", "fixture", [])
    issue = %Issue{id: "issue-failures", identifier: "OXE-FAILURES", state: "Todo"}

    assert :kernel_default ==
             call(:evaluate_admission, [
               issue,
               %{test_pid: self(), result: :kernel_default}
             ])

    assert {:error, delivery_failure, []} =
             call(:handle_delivery, [
               %{type: :workspace_ready},
               %{test_pid: self(), action: :raise, result: :kernel_default}
             ])

    assert delivery_failure.code == :adapter_failure
    assert delivery_failure.reason == :raise

    assert {:error, authorization_failure} =
             call(:authorize, [
               %{kind: :shell},
               %{test_pid: self(), action: :throw, result: :allow}
             ])

    assert authorization_failure.code == :adapter_failure
    assert authorization_failure.reason == :throw
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

    assert :kernel_default ==
             call(:evaluate_admission, [
               %Issue{id: "issue-5", identifier: "OXE-5", state: "Todo"},
               %{test_pid: self(), result: :kernel_default}
             ])

    log = capture_log(fn -> assert :ok == call(:record, [event]) end)

    assert_receive {:delivery_observer, ^event}
    assert log =~ "delivery observer failed"
    refute log =~ "do-not-log"
  end

  test "contains typed and malformed observer errors" do
    install_extensions!("fixture", "fixture", "fixture", ["fixture"])
    issue = %Issue{id: "issue-observer", identifier: "OXE-OBSERVER", state: "Todo"}

    assert :kernel_default ==
             call(:evaluate_admission, [
               issue,
               %{test_pid: self(), result: :kernel_default}
             ])

    observer_failure = %ObserverFailure{code: :fixture_failure, interface: :delivery_observer}

    typed_log =
      capture_log(fn ->
        assert :ok ==
                 call(:record, [
                   %{test_pid: self(), result: {:error, observer_failure}}
                 ])
      end)

    assert typed_log =~ "class=adapter_error"

    malformed_log =
      capture_log(fn ->
        assert :ok == call(:record, [%{test_pid: self(), result: :malformed}])
      end)

    assert malformed_log =~ "class=invalid_adapter_return"
  end

  test "normalizes a missing workflow at every decision entry point" do
    workflow_path = Workflow.workflow_file_path()
    missing_path = Path.join(Path.dirname(workflow_path), "MISSING_OXE_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    Workflow.set_workflow_file_path(missing_path)

    try do
      issue = %Issue{id: "issue-missing", identifier: "OXE-MISSING", state: "Todo"}
      assert {:error, admission_failure} = call(:evaluate_admission, [issue, %{}])
      assert admission_failure.code == :extension_configuration_unavailable
      assert admission_failure.interface == :dispatch_admission
      assert admission_failure.reason == :workflow_unavailable

      assert {:error, delivery_failure, []} =
               call(:handle_delivery, [%{type: :workspace_ready}, %{}])

      assert delivery_failure.code == :extension_configuration_unavailable
      assert delivery_failure.interface == :delivery_controller
      assert delivery_failure.reason == :workflow_unavailable

      assert {:error, authorization_failure} = call(:authorize, [%{kind: :shell}, %{}])
      assert authorization_failure.code == :extension_configuration_unavailable
      assert authorization_failure.interface == :command_authorization
      assert authorization_failure.reason == :workflow_unavailable

      log = capture_log(fn -> assert :ok == call(:record, [%{secret: "not-for-logs"}]) end)
      assert log =~ "registry_unavailable"
      refute log =~ "not-for-logs"
    after
      Workflow.set_workflow_file_path(workflow_path)
      assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
    end
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
      ExtensionRegistry.reset_for_test()
    else
      :ok
    end
  end
end
