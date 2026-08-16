defmodule SymphonyElixir.ExtensionsHostTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ExtensionRegistry
  alias SymphonyElixir.Extensions
  alias SymphonyElixir.Extensions.ObserverFailure

  @fixture_recipient :oxe11_extension_fixture_recipient
  @production_modules [
    SymphonyElixir.Extensions,
    SymphonyElixir.ExtensionRegistry,
    SymphonyElixir.Extensions.AdmissionContext,
    SymphonyElixir.Extensions.AppServerAuthorization,
    SymphonyElixir.Extensions.CommandIntent,
    SymphonyElixir.Extensions.CommandIntentParser,
    SymphonyElixir.Extensions.DeliveryContext,
    SymphonyElixir.Extensions.DeliveryEvent,
    SymphonyElixir.Extensions.DispatchAdmission,
    SymphonyElixir.Extensions.DeliveryController,
    SymphonyElixir.Extensions.CommandAuthorization,
    SymphonyElixir.Extensions.TurnContext,
    SymphonyElixir.Extensions.TurnSeed,
    SymphonyElixir.Extensions.DeliveryObserver,
    SymphonyElixir.Extensions.Noop.DispatchAdmission,
    SymphonyElixir.Extensions.Noop.DeliveryController,
    SymphonyElixir.Extensions.Noop.CommandAuthorization,
    SymphonyElixir.Extensions.Noop.DeliveryObserver
  ]

  setup do
    reset_registry_if_available()
    refute Process.whereis(@fixture_recipient)
    Process.register(self(), @fixture_recipient)
    on_exit(&reset_registry_if_available/0)
  end

  test "routes every facade operation through the locked registry" do
    install_extensions!("fixture", "fixture", "fixture", ["fixture"], %{
      "authorization_result" => "allow",
      "marker" => "fixture"
    })

    issue = %Issue{id: "issue-1", identifier: "OXE-1", state: "Todo"}
    facts = delivery_facts(issue)
    event = %{type: :notification, test_pid: self()}

    assert :kernel_default == call(:evaluate_admission, [issue, 0])
    assert_receive {:dispatch_admission, ^issue, admission_context}

    assert admission_context.options == %{
             "authorization_result" => "allow",
             "marker" => "fixture"
           }

    assert :kernel_default == call(:handle_delivery, [:workspace_ready, facts])
    assert_receive {:delivery_controller, delivery_event, delivery_context}
    assert delivery_event.type == :workspace_ready
    assert delivery_context.issue == issue

    assert delivery_context.options == %{
             "authorization_result" => "allow",
             "marker" => "fixture"
           }

    turn_context = capture_turn_context!(issue)
    request = authorization_request()
    assert :allow == call(:authorize, [request, turn_context])
    assert_receive {:command_authorization, intent, ^turn_context}
    assert %Extensions.CommandIntent{} = intent

    assert :ok == call(:record, [event])
    assert_receive {:delivery_observer, ^event}
  end

  test "returns kernel_default through every production no-op decision interface" do
    issue = %Issue{id: "issue-2", identifier: "OXE-2", state: "Todo"}
    context = capture_turn_context!(issue)
    intent = closed_authorization_intent()

    assert :kernel_default == call(:evaluate_admission, [issue, 0])
    assert :kernel_default == call(:handle_delivery, [:workspace_ready, delivery_facts(issue)])
    assert :kernel_default == authorize_for(issue)
    assert :kernel_default == Extensions.Noop.CommandAuthorization.authorize(intent, context)
    assert :ok == call(:record, [%{type: :notification}])
  end

  test "lazily locks valid configuration from either direct decision entry point" do
    issue = %Issue{id: "issue-lazy", identifier: "OXE-LAZY", state: "Todo"}
    assert :kernel_default == call(:handle_delivery, [:workspace_ready, delivery_facts(issue)])

    reset_registry_if_available()

    assert :kernel_default == authorize_for(issue)
    assert :ok == call(:record, [%{type: :notification}])
  end

  test "accepts valid typed decisions and stamps adapter failures at the facade" do
    install_extensions!("fixture", "fixture", "fixture", [], %{
      "admission_result" => "admit",
      "authorization_result" => "allow_once",
      "delivery_result" => "continue"
    })

    issue = %Issue{id: "issue-typed", identifier: "OXE-TYPED", state: "Todo"}

    assert {:admit, %{issue_id: "issue-typed"}} =
             call(:evaluate_admission, [issue, 0])

    assert {:ok, :continue, [%{type: :continued}]} =
             call(:handle_delivery, [:workspace_ready, delivery_facts(issue)])

    assert {:allow_once, %{lease: "one"}} = authorize_for(issue)

    configure_extension_options!(%{
      "admission_result" => "error",
      "authorization_result" => "error",
      "delivery_result" => "error"
    })

    assert {:error, stamped_admission} =
             call(:evaluate_admission, [issue, 0])

    assert stamped_admission.adapter == SymphonyElixir.ExtensionHostFixtures.DispatchAdmission
    assert String.starts_with?(stamped_admission.registry_revision, "sha256:")

    assert {:error, stamped_delivery, [%{type: :evidence}]} =
             call(:handle_delivery, [:workspace_ready, delivery_facts(issue)])

    assert stamped_delivery.adapter == SymphonyElixir.ExtensionHostFixtures.DeliveryController
    assert String.starts_with?(stamped_delivery.registry_revision, "sha256:")

    assert {:error, stamped_authorization} = authorize_for(issue)

    assert stamped_authorization.adapter ==
             SymphonyElixir.ExtensionHostFixtures.CommandAuthorization

    assert String.starts_with?(stamped_authorization.registry_revision, "sha256:")
  end

  test "rejects malformed adapter returns instead of falling back" do
    install_extensions!("fixture", "fixture", "fixture", [], %{
      "admission_result" => "malformed",
      "authorization_result" => "malformed",
      "delivery_result" => "malformed"
    })

    issue = %Issue{id: "issue-3", identifier: "OXE-3", state: "Todo"}

    assert {:error, admission_failure} =
             call(:evaluate_admission, [issue, 0])

    assert admission_failure.code == :invalid_adapter_return
    assert admission_failure.interface == :dispatch_admission

    assert {:error, delivery_failure, []} =
             call(:handle_delivery, [:workspace_ready, delivery_facts(issue)])

    assert delivery_failure.code == :invalid_adapter_return
    assert delivery_failure.interface == :delivery_controller

    assert {:error, authorization_failure} = authorize_for(issue)

    assert authorization_failure.code == :invalid_adapter_return
    assert authorization_failure.interface == :command_authorization
  end

  test "rejects invalid registry configuration before invoking admission" do
    install_extensions!("not-installed", "noop", "noop", ["noop"])
    issue = %Issue{id: "issue-invalid", identifier: "OXE-INVALID", state: "Todo"}

    assert {:error, failure} = call(:evaluate_admission, [issue, 0])
    assert failure.code == :unknown_adapter
    assert failure.interface == :dispatch_admission
    assert failure.adapter == nil
  end

  test "rejects invalid registry configuration from direct decision entry points" do
    install_extensions!("noop", "not-installed", "noop", ["noop"])
    issue = %Issue{id: "issue-invalid-direct", identifier: "OXE-INVALID-DIRECT", state: "Todo"}

    assert {:error, delivery_failure, []} =
             call(:handle_delivery, [:workspace_ready, delivery_facts(issue)])

    assert delivery_failure.code == :unknown_adapter
    assert delivery_failure.interface == :delivery_controller

    reset_registry_if_available()
    install_extensions!("noop", "noop", "not-installed", ["noop"])

    assert {:error, authorization_failure} = capture_turn(issue)
    assert authorization_failure.code == :unknown_adapter
    assert authorization_failure.interface == :command_authorization
  end

  test "rejects malformed options from direct decision entry points" do
    malformed_options = """
    extensions:
      options: []
    """

    issue = %Issue{id: "issue-options", identifier: "OXE-OPTIONS", state: "Todo"}

    install_extension_stanza!(malformed_options)

    assert {:error, delivery_failure, []} =
             call(:handle_delivery, [:workspace_ready, delivery_facts(issue)])

    assert delivery_failure.code == :invalid_type
    assert delivery_failure.interface == :delivery_controller

    reset_registry_if_available()
    install_extension_stanza!(malformed_options)

    assert {:error, authorization_failure} = capture_turn(issue)
    assert authorization_failure.code == :invalid_type
    assert authorization_failure.interface == nil
  end

  test "fails direct decision entry points closed after selector drift" do
    issue = %Issue{id: "issue-drift", identifier: "OXE-DRIFT", state: "Todo"}
    assert :kernel_default == call(:handle_delivery, [:workspace_ready, delivery_facts(issue)])
    install_extensions!("noop", "fixture", "noop", ["noop"])

    assert {:error, delivery_failure, []} =
             call(:handle_delivery, [:workspace_ready, delivery_facts(issue)])

    assert delivery_failure.code == :extension_registry_restart_required
    assert delivery_failure.interface == :delivery_controller

    reset_registry_if_available()
    install_extensions!("noop", "noop", "noop", ["noop"])
    context = capture_turn_context!(issue)
    assert :kernel_default == call(:authorize, [authorization_request(), context])
    install_extensions!("noop", "noop", "fixture", ["noop"])

    assert {:error, authorization_failure} =
             call(:authorize, [authorization_request(), context])

    assert authorization_failure.code == :extension_registry_restart_required
    assert authorization_failure.interface == :command_authorization
  end

  test "normalizes delivery and authorization adapter failures" do
    install_extensions!("fixture", "fixture", "fixture", [], %{
      "authorization_action" => "throw",
      "delivery_action" => "raise"
    })

    issue = %Issue{id: "issue-failures", identifier: "OXE-FAILURES", state: "Todo"}

    assert :kernel_default ==
             call(:evaluate_admission, [issue, 0])

    assert {:error, delivery_failure, []} =
             call(:handle_delivery, [:workspace_ready, delivery_facts(issue)])

    assert delivery_failure.code == :adapter_failure
    assert delivery_failure.reason == :raise

    assert {:error, authorization_failure} = authorize_for(issue)

    assert authorization_failure.code == :adapter_failure
    assert authorization_failure.reason == :throw
  end

  test "normalizes adapter raise, throw, and exit without neutral fallback" do
    install_extensions!("fixture", "fixture", "fixture", [])
    issue = %Issue{id: "issue-4", identifier: "OXE-4", state: "Todo"}

    for action <- [:raise, :throw, :exit] do
      configure_extension_options!(%{"admission_action" => Atom.to_string(action)})

      assert {:error, failure} =
               call(:evaluate_admission, [issue, 0])

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
               0
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
             call(:evaluate_admission, [issue, 0])

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
      assert {:error, admission_failure} = call(:evaluate_admission, [issue, 0])
      assert admission_failure.code == :extension_configuration_unavailable
      assert admission_failure.interface == :dispatch_admission
      assert admission_failure.reason == :workflow_unavailable

      assert {:error, delivery_failure, []} =
               call(:handle_delivery, [:workspace_ready, delivery_facts(issue)])

      assert delivery_failure.code == :extension_configuration_unavailable
      assert delivery_failure.interface == :delivery_controller
      assert delivery_failure.reason == :workflow_unavailable

      assert {:error, authorization_failure} = capture_turn(issue)
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

  defp authorize_for(issue) do
    context = capture_turn_context!(issue)
    call(:authorize, [authorization_request(), context])
  end

  defp capture_turn(issue) do
    call(:capture_turn, [
      {issue, "/tmp/#{issue.identifier}", nil, "thread-host-fixture"}
    ])
  end

  defp capture_turn_context!(issue) do
    assert {:ok, seed} = capture_turn(issue)
    assert {:ok, context} = call(:bind_turn, [seed, "turn-host-fixture"])
    context
  end

  defp authorization_request do
    {"item/fileChange/requestApproval",
     %{
       "id" => 501,
       "method" => "item/fileChange/requestApproval",
       "params" => %{
         "itemId" => "item-host-fixture",
         "threadId" => "thread-host-fixture",
         "turnId" => "turn-host-fixture"
       }
     }}
  end

  defp closed_authorization_intent do
    %Extensions.CommandIntent{
      request_id: 501,
      operation: %Extensions.CommandIntent.FileChangeApproval{
        grant_root: nil,
        item_id: "item-host-fixture",
        reason: nil,
        thread_id: "thread-host-fixture",
        turn_id: "turn-host-fixture"
      }
    }
  end

  defp install_extensions!(
         admission,
         delivery,
         authorization,
         observers,
         options \\ %{"marker" => "fixture"}
       ) do
    stanza = """
    extensions:
      dispatch_admission: #{admission}
      delivery_controller: #{delivery}
      command_authorization: #{authorization}
      observers: [#{Enum.join(observers, ", ")}]
      options: #{Jason.encode!(options)}
    """

    install_extension_stanza!(stanza)
  end

  defp configure_extension_options!(options) do
    path = Workflow.workflow_file_path()
    source = File.read!(path)

    updated =
      Regex.replace(
        ~r/^  options: .*$/m,
        source,
        "  options: #{Jason.encode!(options)}",
        global: false
      )

    refute updated == source
    File.write!(path, updated)
    assert :ok = WorkflowStore.force_reload()
  end

  defp delivery_facts(issue) do
    {issue, "/tmp/#{issue.identifier}", nil, 0}
  end

  defp install_extension_stanza!(stanza) do
    path = Workflow.workflow_file_path()
    source = File.read!(path)

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
