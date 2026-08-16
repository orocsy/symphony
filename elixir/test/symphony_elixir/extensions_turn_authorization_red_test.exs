defmodule SymphonyElixir.ExtensionsTurnAuthorizationRedTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ExtensionRegistry
  alias SymphonyElixir.Extensions
  alias SymphonyElixir.Extensions.ExtensionFailure

  @fixture_recipient :oxe13_extension_fixture_recipient
  @split_line_bytes 1_048_700
  @protocol_names [
    :command_execution,
    :file_change,
    :legacy_exec_command,
    :legacy_apply_patch,
    :dynamic_tool_call,
    :tool_approval
  ]
  @adapter_failure_actions ["error", "malformed", "raise", "throw", "exit"]
  @malformed_target_names [
    :command_missing_thread,
    :command_invalid_action,
    :command_invalid_network_protocol,
    :command_invalid_network_amendment,
    :file_missing_item,
    :legacy_exec_invalid_action,
    :legacy_patch_invalid_change,
    :dynamic_missing_tool,
    :dynamic_missing_arguments
  ]
  @malformed_request_id_names [
    :command_missing_id,
    :command_boolean_id,
    :legacy_nil_id,
    :legacy_list_id,
    :dynamic_map_id,
    :dynamic_float_id
  ]
  @correlation_mismatch_names [
    :command_thread,
    :command_turn,
    :file_thread,
    :file_turn,
    :legacy_conversation,
    :legacy_patch_conversation,
    :dynamic_thread,
    :dynamic_turn,
    :tool_approval_thread,
    :tool_approval_turn
  ]
  @dynamic_argument_names [:null, :boolean, :number, :string, :list]

  setup do
    reset_registry!()
    refute Process.whereis(@fixture_recipient)
    Process.register(self(), @fixture_recipient)

    on_exit(fn -> reset_registry!() end)
    :ok
  end

  test "facade captures immutable turn authority and passes only a closed product to the adapter" do
    configure_extensions!(%{"marker" => "first"})
    issue = issue("turn-context", "OXE-TURN-CONTEXT")
    facts = {issue, "/tmp/oxe-turn-context", "worker-a", "thread-protocol"}

    assert {:ok, seed} = call(:capture_turn, [facts])
    assert {:ok, registry} = ExtensionRegistry.current()

    assert canonical_term(seed) == %{
             __struct__: SymphonyElixir.Extensions.TurnSeed,
             issue: canonical_term(issue),
             options: %{"marker" => "first"},
             registry_revision: registry.revision,
             thread_id: "thread-protocol",
             worker_host: "worker-a",
             workspace: "/tmp/oxe-turn-context"
           }

    assert {:ok, context} = call(:bind_turn, [seed, "turn-protocol"])

    assert canonical_term(context) == %{
             __struct__: SymphonyElixir.Extensions.TurnContext,
             issue: canonical_term(issue),
             options: %{"marker" => "first"},
             registry_revision: registry.revision,
             thread_id: "thread-protocol",
             turn_id: "turn-protocol",
             worker_host: "worker-a",
             workspace: "/tmp/oxe-turn-context"
           }

    {method, payload} = protocol_case(:command_execution).request
    assert :kernel_default == Extensions.authorize({method, payload}, context)
    assert_receive {:oxe13_authorization, _pid, intent, ^context}
    assert_closed_intent(intent, protocol_case(:command_execution))

    configure_extension_options!(%{"marker" => "second"})
    assert :kernel_default == Extensions.authorize({method, payload}, context)
    assert_receive {:oxe13_authorization, _pid, next_intent, same_context}
    assert_closed_intent(next_intent, protocol_case(:command_execution))
    assert same_context == context
    assert same_context.options == %{"marker" => "first"}

    assert {:ok, next_seed} = call(:capture_turn, [facts])

    assert canonical_term(next_seed) == %{
             __struct__: SymphonyElixir.Extensions.TurnSeed,
             issue: canonical_term(issue),
             options: %{"marker" => "second"},
             registry_revision: context.registry_revision,
             thread_id: "thread-protocol",
             worker_host: "worker-a",
             workspace: "/tmp/oxe-turn-context"
           }

    {dynamic_method, dynamic_payload} = protocol_case(:dynamic_tool_call).request
    scalar_payload = put_in(dynamic_payload, ["params", "arguments"], ["valid", "json"])
    assert :kernel_default == Extensions.authorize({dynamic_method, scalar_payload}, context)
    assert_receive {:oxe13_authorization, _pid, scalar_intent, ^context}

    scalar_protocol =
      :dynamic_tool_call
      |> protocol_case()
      |> put_in([:request], {dynamic_method, scalar_payload})
      |> put_in([:expected_operation, :arguments], ["valid", "json"])

    assert_closed_intent(scalar_intent, scalar_protocol)

    for {wire_protocol, normalized_protocol, wire_action, normalized_action} <-
          network_variant_cases() do
      variant =
        command_network_variant(
          wire_protocol,
          normalized_protocol,
          wire_action,
          normalized_action
        )

      assert :kernel_default == Extensions.authorize(variant.request, context)
      assert_receive {:oxe13_authorization, _pid, variant_intent, ^context}
      assert_closed_intent(variant_intent, variant)
    end
  end

  test "facade rejects malformed turn facts and bypasses malformed request facts before adapter invocation" do
    configure_extensions!(%{})
    issue = issue("invalid-turn", "OXE-INVALID-TURN")

    invalid_turn_facts = [
      {issue, "/tmp/invalid", nil},
      {%{}, "/tmp/invalid", nil, "thread-valid"},
      {issue, nil, nil, "thread-valid"},
      {issue, "", nil, "thread-valid"},
      {issue, "/tmp/invalid", 17, "thread-valid"},
      {issue, "/tmp/invalid", "", "thread-valid"},
      {issue, "/tmp/invalid", nil, nil},
      {issue, "/tmp/invalid", nil, ""}
    ]

    for invalid_facts <- invalid_turn_facts do
      assert {:error,
              %ExtensionFailure{
                code: :invalid_kernel_input,
                interface: :command_authorization,
                adapter: nil,
                registry_revision: nil,
                reason: :turn_facts_invalid
              }} = call(:capture_turn, [invalid_facts])
    end

    assert {:error, %ExtensionFailure{code: :extension_registry_unavailable}} =
             ExtensionRegistry.current()

    assert {:ok, seed} =
             call(:capture_turn, [{issue, "/tmp/valid", nil, "thread-valid"}])

    assert {:error,
            %ExtensionFailure{
              code: :invalid_kernel_input,
              interface: :command_authorization,
              reason: :turn_seed_invalid
            }} = call(:bind_turn, [%{}, "turn-valid"])

    assert {:error,
            %ExtensionFailure{
              code: :invalid_kernel_input,
              interface: :command_authorization,
              reason: :turn_id_invalid
            }} = call(:bind_turn, [seed, nil])

    assert {:error, %ExtensionFailure{reason: :turn_id_invalid}} =
             call(:bind_turn, [seed, ""])

    assert {:ok, context} = call(:bind_turn, [seed, "turn-valid"])

    invalid_requests = [
      {"item/commandExecution/requestApproval", %{"id" => nil, "params" => %{}}},
      {"item/fileChange/requestApproval", %{"id" => 2, "params" => []}},
      {"item/tool/call", %{"id" => 3, "params" => %{"tool" => "linear_graphql"}}},
      {"unknown/method", %{"id" => 4, "params" => %{}}},
      :not_request_facts
    ]

    for invalid <- invalid_requests do
      case invalid do
        :not_request_facts ->
          assert {:error,
                  %ExtensionFailure{
                    code: :invalid_kernel_input,
                    interface: :command_authorization,
                    reason: :command_request_facts_invalid
                  }} = Extensions.authorize(invalid, context)

        _valid_container ->
          assert {:error,
                  %ExtensionFailure{
                    code: :command_intent_invalid,
                    interface: :command_authorization
                  }} = Extensions.authorize(invalid, context)
      end
    end

    refute_receive {:oxe13_authorization, _, _, _}
  end

  test "facade covers optional protocol fields and rejects every retained boundary shape" do
    configure_extensions!(%{})
    current_issue = issue("parser-boundaries", "OXE-PARSER-BOUNDARIES")

    assert {:ok, seed} =
             call(:capture_turn, [
               {current_issue, "/tmp/parser-boundaries", nil, "thread-protocol"}
             ])

    assert {:ok, context} = call(:bind_turn, [seed, "turn-protocol"])

    {command_method, command_payload} = protocol_case(:command_execution).request

    omitted_command_payload =
      update_in(command_payload, ["params"], fn params ->
        Map.drop(params, [
          "approvalId",
          "command",
          "commandActions",
          "cwd",
          "networkApprovalContext",
          "proposedExecpolicyAmendment",
          "proposedNetworkPolicyAmendments",
          "reason"
        ])
      end)

    assert :kernel_default == Extensions.authorize({command_method, omitted_command_payload}, context)

    assert_receive {:oxe13_authorization, _pid,
                    %Extensions.CommandIntent{
                      operation: %Extensions.CommandIntent.CommandExecution{
                        approval_id: nil,
                        command: nil,
                        command_actions: nil,
                        cwd: nil,
                        network_approval: nil,
                        proposed_execpolicy_amendment: nil,
                        proposed_network_policy_amendments: nil,
                        reason: nil
                      }
                    }, ^context}

    nil_command_payload =
      command_payload
      |> put_in(["params", "commandActions"], nil)
      |> put_in(["params", "networkApprovalContext"], nil)
      |> put_in(["params", "proposedExecpolicyAmendment"], nil)
      |> put_in(["params", "proposedNetworkPolicyAmendments"], nil)

    assert :kernel_default == Extensions.authorize({command_method, nil_command_payload}, context)
    assert_receive {:oxe13_authorization, _pid, %Extensions.CommandIntent{}, ^context}

    {tool_method, tool_payload} = protocol_case(:tool_approval).request

    optional_boolean_payload =
      update_in(tool_payload, ["params", "questions"], fn questions ->
        Enum.map(questions, &Map.drop(&1, ["isOther", "isSecret"]))
      end)

    assert :kernel_default == Extensions.authorize({tool_method, optional_boolean_payload}, context)
    assert_receive {:oxe13_authorization, _pid, %Extensions.CommandIntent{}, ^context}

    invalid_cases = [
      {{command_method, Map.put(command_payload, "method", "item/fileChange/requestApproval")}, :request_method_mismatch},
      {mutate_params(command_method, command_payload, &Map.put(&1, "approvalId", 17)), :optional_binary_invalid},
      {mutate_params(command_method, command_payload, &Map.put(&1, "cwd", "relative")), :absolute_path_invalid},
      {mutate_params(command_method, command_payload, &Map.put(&1, "cwd", 17)), :optional_binary_invalid},
      {mutate_params(command_method, command_payload, &Map.put(&1, "networkApprovalContext", [])), :network_approval_invalid},
      {mutate_params(command_method, command_payload, fn params ->
         Map.put(params, "proposedNetworkPolicyAmendments", ["not-an-amendment"])
       end), :network_amendment_invalid},
      {mutate_params(command_method, command_payload, fn params ->
         Map.put(params, "proposedExecpolicyAmendment", ["git", 17])
       end), :string_list_invalid},
      {mutate_params(command_method, command_payload, fn params ->
         Map.put(params, "proposedExecpolicyAmendment", "git")
       end), :string_list_invalid},
      {mutate_params(command_method, command_payload, &Map.put(&1, "commandActions", %{})), :optional_list_invalid},
      {mutate_protocol_request(:legacy_exec_command, &Map.delete(&1, "command")), :string_list_invalid},
      {mutate_protocol_request(:legacy_exec_command, &Map.put(&1, "command", ["git", 17])), :string_list_invalid},
      {mutate_protocol_request(:legacy_exec_command, &Map.put(&1, "parsedCmd", %{})), :required_list_invalid},
      {mutate_protocol_request(:legacy_apply_patch, &Map.put(&1, "fileChanges", [])), :file_changes_invalid},
      {mutate_protocol_request(:dynamic_tool_call, &Map.put(&1, "arguments", :not_json)), :json_invalid},
      {mutate_protocol_request(:tool_approval, fn params ->
         update_in(params, ["questions", Access.at(0), "options"], fn _options -> [] end)
       end), :approval_options_empty},
      {mutate_protocol_request(:tool_approval, fn params ->
         put_in(params, ["questions", Access.at(0), "isOther"], "false")
       end), :optional_boolean_invalid}
    ]

    for {request, reason} <- invalid_cases do
      assert {:error,
              %ExtensionFailure{
                code: :command_intent_invalid,
                interface: :command_authorization,
                reason: ^reason
              }} = Extensions.authorize(request, context)
    end

    refute_receive {:oxe13_authorization, _, _, _}
  end

  test "facade rejects mutated authority and preserves start and closed-port boundaries" do
    configure_extensions!(%{})
    current_issue = issue("authority-boundaries", "OXE-AUTHORITY-BOUNDARIES")
    facts = {current_issue, "/tmp/authority-boundaries", nil, "thread-protocol"}

    assert {:ok, seed} = call(:capture_turn, [facts])

    assert {:error, %ExtensionFailure{reason: :turn_seed_invalid}} =
             call(:bind_turn, [%{seed | options: []}, "turn-protocol"])

    assert {:ok, context} = call(:bind_turn, [seed, "turn-protocol"])
    request = protocol_case(:file_change).request

    assert {:error, %ExtensionFailure{reason: :turn_context_invalid}} =
             Extensions.authorize(request, %{context | options: []})

    assert {:error,
            %ExtensionFailure{
              code: :extension_registry_restart_required,
              reason: :turn_registry_revision_changed
            }} = Extensions.authorize(request, %{context | registry_revision: "sha256:forged"})

    assert {:error, :fixture_start_failed} =
             call(:capture_turn, [
               facts,
               fn -> {:error, :fixture_start_failed} end,
               fn -> flunk("a pre-start failure must not invalidate a valid session") end
             ])

    port = Port.open({:spawn_executable, "/bin/cat"}, [:binary])
    Port.close(port)
    test_pid = self()

    unsafe_request =
      protocol_case(:command_execution).request
      |> then(fn {method, payload} -> {method, Map.delete(payload, "id")} end)

    {method, payload} = unsafe_request

    on_message = fn event -> send(test_pid, {:closed_port_event, event}) end
    tool_executor = fn _tool, _arguments -> %{} end

    facts =
      {port, method, payload, Jason.encode!(payload), on_message, %{}, tool_executor, false}

    fallback = fn _, _, _, _, _, _, _, _ ->
      flunk("unsafe authorization must not use the kernel fallback")
    end

    assert {:unsafe_input_required, %{code: :command_intent_invalid, interface: :command_authorization}} =
             call(:handle_turn_authorization, [facts, context, fallback])

    assert_receive {:closed_port_event, %{event: :authorization_invalid, code: :command_intent_invalid}}
  end

  test "turn capture normalizes unavailable workflow and invalid extension options" do
    workflow_path = Workflow.workflow_file_path()
    fixture_root = unique_root("capture-configuration")
    missing_path = Path.join(fixture_root, "MISSING_WORKFLOW.md")
    invalid_path = Path.join(fixture_root, "INVALID_WORKFLOW.md")
    File.mkdir_p!(fixture_root)

    File.write!(invalid_path, """
    ---
    extensions:
      command_authorization: turn_fixture
      options: [not, a, map]
    ---
    Invalid extension options fixture
    """)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    try do
      current_issue = issue("capture-config", "OXE-CAPTURE-CONFIG")
      facts = {current_issue, "/tmp/capture-config", nil, "thread-capture-config"}
      Workflow.set_workflow_file_path(missing_path)

      assert {:error,
              %ExtensionFailure{
                code: :extension_configuration_unavailable,
                interface: :command_authorization,
                reason: :workflow_unavailable
              }} = call(:capture_turn, [facts])

      Workflow.set_workflow_file_path(invalid_path)

      assert {:error,
              %ExtensionFailure{
                code: :invalid_type,
                interface: nil,
                reason: :options_must_be_map
              }} = call(:capture_turn, [facts])
    after
      Workflow.set_workflow_file_path(workflow_path)
      assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
      File.rm_rf(fixture_root)
    end
  end

  test "turn-context failure is typed and sends no turn request or subscriber message" do
    fixture =
      setup_fake_turn!("capture-drift", protocol_case(:command_execution).request, options: %{"secret" => "capture-options-do-not-log"})

    assert {:ok, original_session} = AppServer.start_session(fixture.workspace)
    session = %{original_session | worker_host: "worker-host-do-not-log"}
    on_exit(fn -> AppServer.stop_session(session) end)

    assert {:ok, %{config: config}} = Workflow.current()
    assert {:ok, registry, _options} = ExtensionRegistry.lock(config)
    configure_authorization!("noop")

    before_turn = client_payloads(fixture.trace_file)
    test_pid = self()

    expected_failure =
      {:error, {:extension_turn_context_failed, :extension_registry_restart_required, :command_authorization}}

    log =
      capture_log(fn ->
        assert expected_failure ==
                 AppServer.run_turn(session, "must not start", fixture.issue, on_message: &send(test_pid, {:oxe13_subscriber, &1}))
      end)

    after_turn = client_payloads(fixture.trace_file)
    assert after_turn == before_turn
    refute Enum.any?(after_turn, &(&1["method"] == "turn/start"))
    refute_receive {:oxe13_subscriber, _}
    refute_receive {:oxe13_authorization, _, _, _}

    failure_lines =
      log
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.contains?(&1, "extension turn context failed"))

    assert [failure_line] = failure_lines

    assert [_prefix, failure_message] = String.split(failure_line, "[error] ", parts: 2)

    assert failure_message ==
             "extension turn context failed code=extension_registry_restart_required interface=command_authorization"

    for secret <- [
          "capture-options-do-not-log",
          fixture.issue.id,
          fixture.issue.identifier,
          fixture.issue.title,
          fixture.issue.description,
          fixture.workspace,
          session.worker_host,
          session.thread_id,
          "turn_fixture",
          inspect(SymphonyElixir.ExtensionTurnFixtures.CommandAuthorization),
          registry.revision,
          "selector_changed"
        ] do
      refute log =~ secret
    end
  end

  test "invalid server thread id fails capture and invalidates the unusable session" do
    fixture =
      setup_fake_turn!("invalid-thread-id", :invalid_thread_id, options: %{"secret" => "thread-options-do-not-log"})

    assert {:ok, session} = AppServer.start_session(fixture.workspace)
    on_exit(fn -> AppServer.stop_session(session) end)
    test_pid = self()

    log =
      capture_log(fn ->
        assert {:error, {:extension_turn_context_failed, :invalid_kernel_input, :command_authorization}} =
                 AppServer.run_turn(session, "invalid server thread id", fixture.issue, on_message: &send(test_pid, {:oxe13_subscriber, &1}))
      end)

    assert :undefined == :erlang.port_info(session.port)
    refute_receive {:oxe13_subscriber, _}
    refute_receive {:oxe13_authorization, _, _, _}
    refute Enum.any?(client_payloads(fixture.trace_file), &(&1["method"] == "turn/start"))

    failure_lines =
      log
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.contains?(&1, "extension turn context failed"))

    assert [failure_line] = failure_lines
    assert [_prefix, failure_message] = String.split(failure_line, "[error] ", parts: 2)

    assert failure_message ==
             "extension turn context failed code=invalid_kernel_input interface=command_authorization"

    for secret <- [
          "thread-options-do-not-log",
          fixture.issue.id,
          fixture.issue.identifier,
          fixture.issue.title,
          fixture.issue.description,
          fixture.workspace,
          "turn_fixture",
          "turn_facts_invalid"
        ] do
      refute log =~ secret
    end
  end

  test "turn binding failure invalidates the post-start session without entering the receive loop" do
    fixture =
      setup_fake_turn!("binding-failure", :invalid_turn_id, options: %{"secret" => "binding-options-do-not-log"})

    assert {:ok, session} = AppServer.start_session(fixture.workspace)
    on_exit(fn -> AppServer.stop_session(session) end)
    test_pid = self()

    log =
      capture_log(fn ->
        assert {:error, {:extension_turn_binding_failed, :invalid_kernel_input, :command_authorization}} =
                 AppServer.run_turn(session, "invalid server turn id", fixture.issue, on_message: &send(test_pid, {:oxe13_subscriber, &1}))
      end)

    assert :undefined == :erlang.port_info(session.port)
    refute_receive {:oxe13_subscriber, _}
    refute_receive {:oxe13_authorization, _, _, _}

    assert Enum.count(client_payloads(fixture.trace_file), &(&1["method"] == "turn/start")) == 1

    failure_lines =
      log
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.contains?(&1, "extension turn binding failed"))

    assert [failure_line] = failure_lines
    assert [_prefix, failure_message] = String.split(failure_line, "[error] ", parts: 2)

    assert failure_message ==
             "extension turn binding failed code=invalid_kernel_input interface=command_authorization"

    for secret <- [
          "binding-options-do-not-log",
          fixture.issue.id,
          fixture.issue.identifier,
          fixture.issue.title,
          fixture.issue.description,
          fixture.workspace,
          session.thread_id,
          "turn_fixture",
          "turn_id_invalid"
        ] do
      refute log =~ secret
    end
  end

  test "unsafe request id invalidates a reusable session inside run_turn" do
    test_case = malformed_request_id_case(:command_missing_id)

    fixture =
      setup_fake_turn!("reusable-session-unsafe-id", test_case.request,
        approval_policy: "never",
        options: %{"secret" => "reusable-session-options-do-not-log"}
      )

    assert {:ok, session} = AppServer.start_session(fixture.workspace)
    on_exit(fn -> AppServer.stop_session(session) end)
    test_pid = self()

    assert {:error, {:turn_input_required, %{code: :command_intent_invalid, interface: :command_authorization}}} =
             AppServer.run_turn(session, "unsafe reusable request id", fixture.issue, on_message: subscriber(test_pid))

    assert :undefined == :erlang.port_info(session.port)
    refute_receive {:oxe13_authorization, _, _, _}

    assert client_payloads(fixture.trace_file)
           |> Enum.reject(&Map.has_key?(&1, "method")) == []

    events = drain_subscriber_messages()
    assert Enum.map(events, & &1.event) == [:session_started, :authorization_invalid]

    assert_exact_authorization_events(
      events,
      {:authorization_invalid, :command_intent_invalid},
      :invalid,
      test_case.method,
      fixture
    )

    inspected = inspect(events, limit: :infinity, printable_limit: :infinity)
    refute inspected =~ "reusable-session-options-do-not-log"
    refute inspected =~ "wire-do-not-leak"
  end

  for protocol_name <- @protocol_names do
    test "#{protocol_name} uses its exact request-scoped authorization responses" do
      protocol = protocol_case(unquote(protocol_name))

      for result <- ["allow", "allow_once", "deny", "error"] do
        reset_registry!()

        fixture =
          setup_fake_turn!("#{protocol.name}-#{result}", protocol.request,
            approval_policy: "never",
            options: %{
              "authorization_result" => result,
              "secret" => "decision-options-do-not-log"
            }
          )

        test_pid = self()
        subscriber = subscriber(test_pid)

        tool_executor = fn tool, arguments ->
          send(test_pid, {:oxe13_tool_executed, tool, arguments})

          %{
            "success" => true,
            "output" => "fixture tool executed",
            "contentItems" => [
              %{"type" => "inputText", "text" => "fixture tool executed"}
            ]
          }
        end

        log =
          capture_log(fn ->
            assert {:ok, _result} =
                     AppServer.run(fixture.workspace, result, fixture.issue,
                       on_message: subscriber,
                       tool_executor: tool_executor
                     )
          end)

        assert_receive {:oxe13_authorization, _pid, intent, context}
        assert context.issue == fixture.issue
        assert_closed_intent(intent, protocol)

        assert response_for(fixture.trace_file, protocol.request_id) ==
                 expected_response(protocol, result)

        refute_receive {:oxe13_tool_executed, _, _}, 10

        events = drain_subscriber_messages()
        assert_authorization_events(events, protocol, result, fixture)
        assert_log_redacted(log, protocol, fixture, "decision-options-do-not-log")
      end
    end
  end

  for protocol_name <- @protocol_names do
    test "#{protocol_name} accepts and echoes a valid string JSON-RPC request id" do
      protocol = string_id_protocol(unquote(protocol_name))

      fixture =
        setup_fake_turn!("#{protocol.name}-string-id", protocol.request,
          approval_policy: "never",
          options: %{"authorization_result" => "deny"}
        )

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:oxe13_tool_executed, tool, arguments})
        %{"success" => true}
      end

      assert {:ok, _result} =
               AppServer.run(fixture.workspace, "string request id", fixture.issue,
                 on_message: subscriber(test_pid),
                 tool_executor: tool_executor
               )

      assert_receive {:oxe13_authorization, _pid, intent, context}
      assert context.issue == fixture.issue
      assert_closed_intent(intent, protocol)
      refute_receive {:oxe13_tool_executed, _, _}

      assert response_for(fixture.trace_file, protocol.request_id) ==
               expected_response(protocol, "deny")

      events = drain_subscriber_messages()
      assert_authorization_events(events, protocol, "deny", fixture)
    end
  end

  for malformed_name <- @malformed_target_names do
    test "policy never fails closed for malformed targeted request #{malformed_name}" do
      test_case = malformed_target_case(unquote(malformed_name))

      fixture =
        setup_fake_turn!("malformed-target-#{test_case.name}", test_case.request,
          approval_policy: "never",
          options: %{"secret" => "malformed-options-do-not-log"}
        )

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:oxe13_tool_executed, tool, arguments})
        %{"success" => true}
      end

      assert {:ok, _result} =
               AppServer.run(fixture.workspace, "malformed target", fixture.issue,
                 on_message: subscriber(test_pid),
                 tool_executor: tool_executor
               )

      refute_receive {:oxe13_authorization, _, _, _}
      refute_receive {:oxe13_tool_executed, _, _}

      assert response_for(fixture.trace_file, test_case.request_id) ==
               invalid_intent_response(test_case)

      events = drain_subscriber_messages()
      assert_invalid_authorization_event(events, test_case, fixture)
    end
  end

  for malformed_id_name <- @malformed_request_id_names do
    test "policy never emits no response for unsafe request id #{malformed_id_name}" do
      test_case = malformed_request_id_case(unquote(malformed_id_name))

      fixture =
        setup_fake_turn!("malformed-id-#{test_case.name}", test_case.request,
          approval_policy: "never",
          options: %{"secret" => "malformed-id-options-do-not-log"}
        )

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:oxe13_tool_executed, tool, arguments})
        %{"success" => true}
      end

      assert {:error, {:turn_input_required, %{code: :command_intent_invalid, interface: :command_authorization}}} =
               AppServer.run(fixture.workspace, "unsafe request id", fixture.issue,
                 on_message: subscriber(test_pid),
                 tool_executor: tool_executor
               )

      refute_receive {:oxe13_authorization, _, _, _}
      refute_receive {:oxe13_tool_executed, _, _}

      assert client_payloads(fixture.trace_file)
             |> Enum.reject(&Map.has_key?(&1, "method")) == []

      events = drain_subscriber_messages()
      assert Enum.map(events, & &1.event) == [:session_started, :authorization_invalid]

      assert_exact_authorization_events(
        events,
        {:authorization_invalid, :command_intent_invalid},
        :invalid,
        test_case.method,
        fixture
      )

      inspected = inspect(events, limit: :infinity, printable_limit: :infinity)

      for secret <- [
            "malformed-id-options-do-not-log",
            "wire-do-not-leak",
            fixture.issue.title,
            fixture.issue.description,
            fixture.workspace
          ] do
        refute inspected =~ secret
      end
    end
  end

  for mismatch_name <- @correlation_mismatch_names do
    test "rejects active-turn correlation mismatch #{mismatch_name} before adapter invocation" do
      test_case = correlation_mismatch_case(unquote(mismatch_name))

      fixture =
        setup_fake_turn!("mismatch-#{test_case.name}", test_case.request,
          approval_policy: "never",
          options: %{"secret" => "mismatch-options-do-not-log"}
        )

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:oxe13_tool_executed, tool, arguments})
        %{"success" => true}
      end

      assert {:ok, _result} =
               AppServer.run(fixture.workspace, "correlation mismatch", fixture.issue,
                 on_message: subscriber(test_pid),
                 tool_executor: tool_executor
               )

      refute_receive {:oxe13_authorization, _, _, _}
      refute_receive {:oxe13_tool_executed, _, _}

      assert response_for(fixture.trace_file, test_case.request_id) ==
               invalid_intent_response(test_case)

      events = drain_subscriber_messages()
      assert_invalid_authorization_event(events, test_case, fixture)
    end
  end

  for arguments_name <- @dynamic_argument_names do
    test "unvalidated dynamic JSON #{arguments_name} cannot be allowed by a non-noop adapter" do
      protocol = dynamic_argument_protocol(unquote(arguments_name))

      for result <- ["allow", "allow_once"] do
        reset_registry!()

        fixture =
          setup_fake_turn!("dynamic-#{protocol.arguments_name}-#{result}", protocol.request,
            approval_policy: "never",
            options: %{"authorization_result" => result}
          )

        test_pid = self()

        tool_executor = fn tool, arguments ->
          send(test_pid, {:oxe13_tool_executed, tool, arguments})
          %{"success" => true}
        end

        assert {:ok, _result} =
                 AppServer.run(fixture.workspace, "unvalidated JSON", fixture.issue,
                   on_message: subscriber(test_pid),
                   tool_executor: tool_executor
                 )

        assert_receive {:oxe13_authorization, _pid, intent, context}
        assert context.issue == fixture.issue
        assert_closed_intent(intent, protocol)
        refute_receive {:oxe13_tool_executed, _, _}

        assert response_for(fixture.trace_file, protocol.request_id) ==
                 failed_dynamic_tool_response(
                   protocol.request_id,
                   "extension authorization failed"
                 )

        events = drain_subscriber_messages()
        assert_authorization_events(events, protocol, result, fixture)
      end
    end
  end

  test "one context survives split-line ordinary unhandled and approval recursion across reload" do
    fixture =
      setup_fake_turn!("recursive", :recursive,
        approval_policy: "never",
        options: %{
          "authorization_pause" => true,
          "authorization_result" => "allow",
          "marker" => "first"
        }
      )

    test_pid = self()
    on_message = fn message -> send(test_pid, {:oxe13_subscriber, message}) end

    task =
      Task.async(fn ->
        AppServer.run(fixture.workspace, "recursive context", fixture.issue, on_message: on_message)
      end)

    on_exit(fn -> shutdown_task(task) end)

    assert {:oxe13_subscriber, %{event: :session_started}} = next_message(3_000)

    assert {:oxe13_subscriber, %{event: :notification, payload: %{"params" => %{"padding" => padding}}}} =
             next_message(2_000)

    assert byte_size(padding) == @split_line_bytes

    assert {:oxe13_subscriber, %{event: :notification, payload: %{"method" => "future/unknown"}}} =
             next_message()

    assert {:oxe13_authorization, first_pid, first_intent, first_context} = next_message()
    assert_closed_intent(first_intent, protocol_case(:command_execution))
    assert first_context.options["marker"] == "first"

    configure_extension_options!(%{
      "authorization_pause" => true,
      "authorization_result" => "allow",
      "marker" => "second"
    })

    send(first_pid, :oxe13_continue)

    assert {:oxe13_subscriber, %{event: :approval_auto_approved, decision: "accept"}} =
             next_message()

    assert {:oxe13_authorization, second_pid, second_intent, second_context} = next_message()
    assert_closed_intent(second_intent, protocol_case(:file_change))
    assert second_context == first_context
    assert second_context.options["marker"] == "first"
    send(second_pid, :oxe13_continue)

    assert {:oxe13_subscriber, %{event: :approval_auto_approved, decision: "accept"}} =
             next_message()

    assert {:oxe13_subscriber, %{event: :turn_completed}} = next_message()
    assert {:ok, _result} = Task.await(task, 2_000)

    facts = {fixture.issue, fixture.workspace, nil, "thread-protocol"}
    assert {:ok, reloaded_seed} = call(:capture_turn, [facts])
    assert reloaded_seed.options["marker"] == "second"
    assert reloaded_seed.registry_revision == first_context.registry_revision
  end

  test "no-op authorization preserves safer and never approval behavior exactly" do
    request = protocol_case(:command_execution).request

    safer =
      setup_fake_turn!("safer-default", request,
        authorization: "noop",
        options: %{}
      )

    assert {:error, {:approval_required, payload}} =
             AppServer.run(safer.workspace, "safer default", safer.issue)

    assert payload["method"] == "item/commandExecution/requestApproval"
    refute_receive {:oxe13_authorization, _, _, _}

    reset_registry!()

    never =
      setup_fake_turn!("never-default", request,
        approval_policy: "never",
        authorization: "noop",
        options: %{}
      )

    assert {:ok, _result} = AppServer.run(never.workspace, "never default", never.issue)

    assert response_for(never.trace_file, 90) == %{
             "id" => 90,
             "result" => %{"decision" => "acceptForSession"}
           }

    refute_receive {:oxe13_authorization, _, _, _}

    reset_registry!()

    dynamic =
      setup_fake_turn!("dynamic-default", protocol_case(:dynamic_tool_call).request,
        approval_policy: "never",
        authorization: "noop",
        options: %{}
      )

    test_pid = self()

    assert {:ok, _result} =
             AppServer.run(dynamic.workspace, "dynamic default", dynamic.issue,
               tool_executor: fn tool, arguments ->
                 send(test_pid, {:oxe13_tool_executed, tool, arguments})

                 %{
                   "success" => true,
                   "output" => "fixture tool executed",
                   "contentItems" => [
                     %{"type" => "inputText", "text" => "fixture tool executed"}
                   ]
                 }
               end
             )

    assert_receive {:oxe13_tool_executed, "linear_graphql",
                    %{
                      "query" => "query Viewer { viewer { id } }",
                      "variables" => %{}
                    }}

    refute_receive {:oxe13_authorization, _, _, _}
  end

  test "free-form and malformed tool input products bypass authorization" do
    cases = malformed_tool_input_cases()

    actual =
      Enum.map(cases, fn test_case ->
        reset_registry!()

        fixture =
          setup_fake_turn!("malformed-#{test_case.name}", test_case.request,
            approval_policy: "never",
            options: %{}
          )

        fixture.workspace
        |> AppServer.run("malformed input", fixture.issue)
        |> result_class()
      end)

    assert actual == Enum.map(cases, & &1.expected)
    refute_receive {:oxe13_authorization, _, _, _}
  end

  for action <- @adapter_failure_actions do
    test "adapter #{action} is contained by exact response and sanitized subscriber evidence" do
      action = unquote(action)

      options =
        if action in ["error", "malformed"] do
          %{"authorization_result" => action, "secret" => "adapter-options-do-not-log"}
        else
          %{"authorization_action" => action, "secret" => "adapter-options-do-not-log"}
        end

      protocol = protocol_case(:command_execution)

      fixture =
        setup_fake_turn!("adapter-failure-#{action}", protocol.request,
          approval_policy: "never",
          options: options
        )

      log =
        capture_log(fn ->
          assert {:ok, _result} =
                   AppServer.run(fixture.workspace, "adapter failure", fixture.issue, on_message: subscriber(self()))
        end)

      assert_receive {:oxe13_authorization, _pid, intent, context}
      assert context.issue == fixture.issue
      assert_closed_intent(intent, protocol)

      assert response_for(fixture.trace_file, protocol.request_id) ==
               expected_response(protocol, "error")

      events = drain_subscriber_messages()
      assert_authorization_events(events, protocol, "error", fixture)
      assert_log_redacted(log, protocol, fixture, "adapter-options-do-not-log")
    end
  end

  defp protocol_case(:command_execution) do
    read_action = SymphonyElixir.Extensions.CommandIntent.CommandExecution.ReadAction
    list_action = SymphonyElixir.Extensions.CommandIntent.CommandExecution.ListFilesAction
    search_action = SymphonyElixir.Extensions.CommandIntent.CommandExecution.SearchAction
    unknown_action = SymphonyElixir.Extensions.CommandIntent.CommandExecution.UnknownAction
    network_approval = SymphonyElixir.Extensions.CommandIntent.CommandExecution.NetworkApproval
    network_amendment = SymphonyElixir.Extensions.CommandIntent.CommandExecution.NetworkAmendment

    %{
      name: :command_execution,
      request_id: 90,
      operation_module: SymphonyElixir.Extensions.CommandIntent.CommandExecution,
      request:
        {"item/commandExecution/requestApproval",
         %{
           "id" => 90,
           "method" => "item/commandExecution/requestApproval",
           "params" => %{
             "approvalId" => nil,
             "command" => "git status --short",
             "commandActions" => [
               %{"command" => "cat README.md", "name" => "README.md", "path" => "/tmp/README.md", "type" => "read"},
               %{"command" => "find src", "path" => "src", "type" => "listFiles"},
               %{"command" => "rg OXE lib", "path" => "lib", "query" => "OXE", "type" => "search"},
               %{"command" => "git status --short", "type" => "unknown"}
             ],
             "cwd" => "/tmp",
             "itemId" => "item-90",
             "networkApprovalContext" => %{"host" => "api.github.com", "protocol" => "https"},
             "proposedExecpolicyAmendment" => ["prefix_rule([\"git\", \"status\"])"],
             "proposedNetworkPolicyAmendments" => [%{"action" => "allow", "host" => "api.github.com"}],
             "reason" => "inspect workspace",
             "threadId" => "thread-protocol",
             "turnId" => "turn-protocol",
             "wireSecret" => "command-wire-do-not-leak"
           }
         }},
      expected_operation: %{
        approval_id: nil,
        command: "git status --short",
        command_actions: [
          %{__struct__: read_action, command: "cat README.md", name: "README.md", path: "/tmp/README.md"},
          %{__struct__: list_action, command: "find src", path: "/tmp/src"},
          %{__struct__: search_action, command: "rg OXE lib", path: "/tmp/lib", query: "OXE"},
          %{__struct__: unknown_action, command: "git status --short"}
        ],
        cwd: "/tmp",
        item_id: "item-90",
        network_approval: %{__struct__: network_approval, host: "api.github.com", protocol: :https},
        proposed_execpolicy_amendment: ["prefix_rule([\"git\", \"status\"])"],
        proposed_network_policy_amendments: [
          %{__struct__: network_amendment, action: :allow, host: "api.github.com"}
        ],
        reason: "inspect workspace",
        thread_id: "thread-protocol",
        turn_id: "turn-protocol"
      }
    }
  end

  defp protocol_case(:file_change) do
    %{
      name: :file_change,
      request_id: 91,
      operation_module: SymphonyElixir.Extensions.CommandIntent.FileChangeApproval,
      request:
        {"item/fileChange/requestApproval",
         %{
           "id" => 91,
           "method" => "item/fileChange/requestApproval",
           "params" => %{
             "grantRoot" => "/tmp",
             "itemId" => "item-91",
             "reason" => "apply reviewed patch",
             "threadId" => "thread-protocol",
             "turnId" => "turn-protocol",
             "wireSecret" => "file-wire-do-not-leak"
           }
         }},
      expected_operation: %{
        grant_root: "/tmp",
        item_id: "item-91",
        reason: "apply reviewed patch",
        thread_id: "thread-protocol",
        turn_id: "turn-protocol"
      }
    }
  end

  defp protocol_case(:legacy_exec_command) do
    read_action = SymphonyElixir.Extensions.CommandIntent.LegacyExecCommand.ReadAction
    list_action = SymphonyElixir.Extensions.CommandIntent.LegacyExecCommand.ListFilesAction
    search_action = SymphonyElixir.Extensions.CommandIntent.LegacyExecCommand.SearchAction
    unknown_action = SymphonyElixir.Extensions.CommandIntent.LegacyExecCommand.UnknownAction

    %{
      name: :legacy_exec_command,
      request_id: 92,
      operation_module: SymphonyElixir.Extensions.CommandIntent.LegacyExecCommand,
      request:
        {"execCommandApproval",
         %{
           "id" => 92,
           "method" => "execCommandApproval",
           "params" => %{
             "approvalId" => nil,
             "callId" => "call-92",
             "command" => ["git", "status", "--short"],
             "conversationId" => "thread-protocol",
             "cwd" => "/tmp",
             "parsedCmd" => [
               %{"cmd" => "cat README.md", "name" => "README.md", "path" => "/tmp/README.md", "type" => "read"},
               %{"cmd" => "find src", "path" => "src", "type" => "list_files"},
               %{"cmd" => "rg OXE lib", "path" => "lib", "query" => "OXE", "type" => "search"},
               %{"cmd" => "git status --short", "type" => "unknown"}
             ],
             "reason" => "inspect workspace",
             "wireSecret" => "legacy-command-wire-do-not-leak"
           }
         }},
      expected_operation: %{
        approval_id: nil,
        argv: ["git", "status", "--short"],
        call_id: "call-92",
        conversation_id: "thread-protocol",
        cwd: "/tmp",
        parsed_actions: [
          %{__struct__: read_action, command: "cat README.md", name: "README.md", path: "/tmp/README.md"},
          %{__struct__: list_action, command: "find src", path: "/tmp/src"},
          %{__struct__: search_action, command: "rg OXE lib", path: "/tmp/lib", query: "OXE"},
          %{__struct__: unknown_action, command: "git status --short"}
        ],
        reason: "inspect workspace"
      }
    }
  end

  defp protocol_case(:legacy_apply_patch) do
    target_change = SymphonyElixir.Extensions.CommandIntent.LegacyApplyPatch.TargetChange

    %{
      name: :legacy_apply_patch,
      request_id: 93,
      operation_module: SymphonyElixir.Extensions.CommandIntent.LegacyApplyPatch,
      request:
        {"applyPatchApproval",
         %{
           "id" => 93,
           "method" => "applyPatchApproval",
           "params" => %{
             "callId" => "call-93",
             "conversationId" => "thread-protocol",
             "fileChanges" => %{
               "/tmp/created.txt" => %{"content" => "add-content-do-not-cross", "type" => "add"},
               "/tmp/deleted.txt" => %{"content" => "delete-content-do-not-cross", "type" => "delete"},
               "/tmp/updated.txt" => %{
                 "move_path" => "moved.txt",
                 "type" => "update",
                 "unified_diff" => "diff-content-do-not-cross"
               }
             },
             "grantRoot" => "/tmp",
             "reason" => "apply reviewed patch",
             "wireSecret" => "legacy-patch-wire-do-not-leak"
           }
         }},
      expected_operation: %{
        call_id: "call-93",
        changes: [
          %{__struct__: target_change, move_path: nil, operation: :add, path: "/tmp/created.txt"},
          %{__struct__: target_change, move_path: nil, operation: :delete, path: "/tmp/deleted.txt"},
          %{__struct__: target_change, move_path: "/tmp/moved.txt", operation: :update, path: "/tmp/updated.txt"}
        ],
        conversation_id: "thread-protocol",
        grant_root: "/tmp",
        reason: "apply reviewed patch"
      }
    }
  end

  defp protocol_case(:dynamic_tool_call) do
    %{
      name: :dynamic_tool_call,
      request_id: 94,
      operation_module: SymphonyElixir.Extensions.CommandIntent.DynamicToolCall,
      request:
        {"item/tool/call",
         %{
           "id" => 94,
           "method" => "item/tool/call",
           "params" => %{
             "arguments" => %{
               "query" => "query Viewer { viewer { id } }",
               "variables" => %{}
             },
             "callId" => "call-94",
             "threadId" => "thread-protocol",
             "tool" => "linear_graphql",
             "turnId" => "turn-protocol",
             "wireSecret" => "dynamic-wire-do-not-leak"
           }
         }},
      expected_operation: %{
        arguments: %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{}
        },
        arguments_validated?: false,
        call_id: "call-94",
        thread_id: "thread-protocol",
        tool: "linear_graphql",
        turn_id: "turn-protocol"
      }
    }
  end

  defp protocol_case(:tool_approval) do
    question = SymphonyElixir.Extensions.CommandIntent.ToolApproval.Question

    %{
      name: :tool_approval,
      request_id: 95,
      operation_module: SymphonyElixir.Extensions.CommandIntent.ToolApproval,
      request:
        {"item/tool/requestUserInput",
         %{
           "id" => 95,
           "method" => "item/tool/requestUserInput",
           "params" => %{
             "itemId" => "call-95",
             "questions" => [
               approval_question("mcp_tool_call_approval_call-95-a"),
               approval_question("mcp_tool_call_approval_call-95-b")
             ],
             "threadId" => "thread-protocol",
             "turnId" => "turn-protocol",
             "wireSecret" => "tool-approval-wire-do-not-leak"
           }
         }},
      expected_operation: %{
        item_id: "call-95",
        questions: [
          %{__struct__: question, id: "mcp_tool_call_approval_call-95-a", option_labels: ["Approve Once", "Deny"]},
          %{__struct__: question, id: "mcp_tool_call_approval_call-95-b", option_labels: ["Approve Once", "Deny"]}
        ],
        thread_id: "thread-protocol",
        turn_id: "turn-protocol"
      }
    }
  end

  defp string_id_protocol(protocol_name) do
    protocol = protocol_case(protocol_name)
    {method, payload} = protocol.request
    request_id = "request-#{protocol.name}"

    %{protocol | request_id: request_id, request: {method, Map.put(payload, "id", request_id)}}
  end

  defp malformed_target_case(:command_missing_thread) do
    mutate_protocol(:command_execution, :command_missing_thread, fn params ->
      Map.delete(params, "threadId")
    end)
  end

  defp malformed_target_case(:command_invalid_action) do
    mutate_protocol(:command_execution, :command_invalid_action, fn params ->
      Map.put(params, "commandActions", [
        %{"command" => "cat README.md", "type" => "read"}
      ])
    end)
  end

  defp malformed_target_case(:command_invalid_network_protocol) do
    mutate_protocol(:command_execution, :command_invalid_network_protocol, fn params ->
      put_in(params, ["networkApprovalContext", "protocol"], "ftp")
    end)
  end

  defp malformed_target_case(:command_invalid_network_amendment) do
    mutate_protocol(:command_execution, :command_invalid_network_amendment, fn params ->
      put_in(params, ["proposedNetworkPolicyAmendments", Access.at(0), "action"], "prompt")
    end)
  end

  defp malformed_target_case(:file_missing_item) do
    mutate_protocol(:file_change, :file_missing_item, fn params ->
      Map.delete(params, "itemId")
    end)
  end

  defp malformed_target_case(:legacy_exec_invalid_action) do
    mutate_protocol(:legacy_exec_command, :legacy_exec_invalid_action, fn params ->
      Map.put(params, "parsedCmd", [%{"cmd" => "cat README.md", "type" => "read"}])
    end)
  end

  defp malformed_target_case(:legacy_patch_invalid_change) do
    mutate_protocol(:legacy_apply_patch, :legacy_patch_invalid_change, fn params ->
      Map.put(params, "fileChanges", %{
        "/tmp/updated.txt" => %{"move_path" => 17, "type" => "update"}
      })
    end)
  end

  defp malformed_target_case(:dynamic_missing_tool) do
    mutate_protocol(:dynamic_tool_call, :dynamic_missing_tool, fn params ->
      Map.delete(params, "tool")
    end)
  end

  defp malformed_target_case(:dynamic_missing_arguments) do
    mutate_protocol(:dynamic_tool_call, :dynamic_missing_arguments, fn params ->
      Map.delete(params, "arguments")
    end)
  end

  defp malformed_request_id_case(:command_missing_id) do
    mutate_request_id(:command_execution, :command_missing_id, :missing)
  end

  defp malformed_request_id_case(:command_boolean_id) do
    mutate_request_id(:command_execution, :command_boolean_id, true)
  end

  defp malformed_request_id_case(:legacy_nil_id) do
    mutate_request_id(:legacy_exec_command, :legacy_nil_id, nil)
  end

  defp malformed_request_id_case(:legacy_list_id) do
    mutate_request_id(:legacy_exec_command, :legacy_list_id, ["unsafe"])
  end

  defp malformed_request_id_case(:dynamic_map_id) do
    mutate_request_id(:dynamic_tool_call, :dynamic_map_id, %{"unsafe" => "id"})
  end

  defp malformed_request_id_case(:dynamic_float_id) do
    mutate_request_id(:dynamic_tool_call, :dynamic_float_id, 17.5)
  end

  defp correlation_mismatch_case(:command_thread) do
    mutate_protocol(:command_execution, :command_thread, fn params ->
      Map.put(params, "threadId", "thread-other")
    end)
  end

  defp correlation_mismatch_case(:command_turn) do
    mutate_protocol(:command_execution, :command_turn, fn params ->
      Map.put(params, "turnId", "turn-other")
    end)
  end

  defp correlation_mismatch_case(:file_thread) do
    mutate_protocol(:file_change, :file_thread, fn params ->
      Map.put(params, "threadId", "thread-other")
    end)
  end

  defp correlation_mismatch_case(:file_turn) do
    mutate_protocol(:file_change, :file_turn, fn params ->
      Map.put(params, "turnId", "turn-other")
    end)
  end

  defp correlation_mismatch_case(:legacy_conversation) do
    mutate_protocol(:legacy_exec_command, :legacy_conversation, fn params ->
      Map.put(params, "conversationId", "thread-other")
    end)
  end

  defp correlation_mismatch_case(:legacy_patch_conversation) do
    mutate_protocol(:legacy_apply_patch, :legacy_patch_conversation, fn params ->
      Map.put(params, "conversationId", "thread-other")
    end)
  end

  defp correlation_mismatch_case(:dynamic_thread) do
    mutate_protocol(:dynamic_tool_call, :dynamic_thread, fn params ->
      Map.put(params, "threadId", "thread-other")
    end)
  end

  defp correlation_mismatch_case(:dynamic_turn) do
    mutate_protocol(:dynamic_tool_call, :dynamic_turn, fn params ->
      Map.put(params, "turnId", "turn-other")
    end)
  end

  defp correlation_mismatch_case(:tool_approval_thread) do
    mutate_protocol(:tool_approval, :tool_approval_thread, fn params ->
      Map.put(params, "threadId", "thread-other")
    end)
  end

  defp correlation_mismatch_case(:tool_approval_turn) do
    mutate_protocol(:tool_approval, :tool_approval_turn, fn params ->
      Map.put(params, "turnId", "turn-other")
    end)
  end

  defp mutate_protocol(protocol_name, case_name, mutate_params) do
    protocol = protocol_case(protocol_name)
    {method, payload} = protocol.request
    mutated_payload = update_in(payload, ["params"], mutate_params)

    %{
      family: protocol_name,
      method: method,
      name: case_name,
      request: {method, mutated_payload},
      request_id: protocol.request_id
    }
  end

  defp mutate_protocol_request(protocol_name, mutate_params) do
    protocol = protocol_case(protocol_name)
    {method, payload} = protocol.request
    mutate_params(method, payload, mutate_params)
  end

  defp mutate_params(method, payload, mutate_params) do
    {method, update_in(payload, ["params"], mutate_params)}
  end

  defp mutate_request_id(protocol_name, case_name, request_id) do
    protocol = protocol_case(protocol_name)
    {method, payload} = protocol.request

    mutated_payload =
      case request_id do
        :missing -> Map.delete(payload, "id")
        value -> Map.put(payload, "id", value)
      end

    %{
      family: protocol_name,
      method: method,
      name: case_name,
      request: {method, mutated_payload}
    }
  end

  defp dynamic_argument_protocol(arguments_name) do
    arguments = dynamic_arguments(arguments_name)
    protocol = protocol_case(:dynamic_tool_call)
    {method, payload} = protocol.request
    request = {method, put_in(payload, ["params", "arguments"], arguments)}

    protocol
    |> Map.put(:arguments_name, arguments_name)
    |> Map.put(:request, request)
    |> put_in([:expected_operation, :arguments], arguments)
  end

  defp dynamic_arguments(:null), do: nil
  defp dynamic_arguments(:boolean), do: true
  defp dynamic_arguments(:number), do: 17.5
  defp dynamic_arguments(:string), do: "opaque JSON"
  defp dynamic_arguments(:list), do: ["valid", %{"nested" => false}]

  defp network_variant_cases do
    [
      {"http", :http, "allow", :allow},
      {"https", :https, "deny", :deny},
      {"socks5Tcp", :socks5_tcp, "allow", :allow},
      {"socks5Udp", :socks5_udp, "deny", :deny}
    ]
  end

  defp command_network_variant(wire_protocol, normalized_protocol, wire_action, normalized_action) do
    protocol = protocol_case(:command_execution)
    {method, payload} = protocol.request

    payload =
      payload
      |> put_in(["params", "networkApprovalContext", "protocol"], wire_protocol)
      |> put_in(["params", "proposedNetworkPolicyAmendments", Access.at(0), "action"], wire_action)

    expected_network_approval = %{
      protocol.expected_operation.network_approval
      | protocol: normalized_protocol
    }

    [first_amendment] = protocol.expected_operation.proposed_network_policy_amendments
    expected_amendments = [%{first_amendment | action: normalized_action}]

    expected_operation = %{
      protocol.expected_operation
      | network_approval: expected_network_approval,
        proposed_network_policy_amendments: expected_amendments
    }

    %{protocol | request: {method, payload}, expected_operation: expected_operation}
  end

  defp malformed_tool_input_cases do
    duplicate_question = approval_question("mcp_tool_call_approval_duplicate")

    [
      %{
        name: :freeform,
        request:
          tool_input_request(111, [
            %{
              "header" => "Provide context",
              "id" => "freeform-111",
              "isOther" => false,
              "isSecret" => false,
              "options" => nil,
              "question" => "What should I post?"
            }
          ]),
        expected: :turn_input_required
      },
      %{
        name: :empty_questions,
        request: tool_input_request(112, []),
        expected: :turn_input_required
      },
      %{
        name: :duplicate_questions,
        request: tool_input_request(113, [duplicate_question, duplicate_question]),
        expected: :turn_input_required
      },
      %{
        name: :missing_label,
        request:
          tool_input_request(114, [
            approval_question("mcp_tool_call_approval_missing", [
              %{"description" => "missing label"}
            ])
          ]),
        expected: :turn_input_required
      },
      %{
        name: :duplicate_labels,
        request:
          tool_input_request(115, [
            approval_question("mcp_tool_call_approval_duplicate_labels", [
              %{"description" => "one", "label" => "Approve Once"},
              %{"description" => "two", "label" => "Approve Once"},
              %{"description" => "deny", "label" => "Deny"}
            ])
          ]),
        expected: :turn_input_required
      },
      %{
        name: :empty_label,
        request:
          tool_input_request(116, [
            approval_question("mcp_tool_call_approval_empty", [
              %{"description" => "empty", "label" => ""},
              %{"description" => "deny", "label" => "Deny"}
            ])
          ]),
        expected: :turn_input_required
      },
      %{
        name: :missing_deny,
        request:
          tool_input_request(117, [
            approval_question("mcp_tool_call_approval_missing_deny", [
              %{"description" => "run once", "label" => "Approve Once"}
            ])
          ]),
        expected: :turn_input_required
      },
      %{
        name: :missing_approve,
        request:
          tool_input_request(118, [
            approval_question("mcp_tool_call_approval_missing_approve", [
              %{"description" => "deny", "label" => "Deny"}
            ])
          ]),
        expected: :turn_input_required
      }
    ]
  end

  defp approval_question(id, options \\ nil) do
    %{
      "header" => "Approve app tool call?",
      "id" => id,
      "isOther" => false,
      "isSecret" => false,
      "options" =>
        options ||
          [
            %{"description" => "Run once", "label" => "Approve Once"},
            %{"description" => "Decline", "label" => "Deny"}
          ],
      "question" => "Allow this action?"
    }
  end

  defp tool_input_request(id, questions) do
    {"item/tool/requestUserInput",
     %{
       "id" => id,
       "method" => "item/tool/requestUserInput",
       "params" => %{
         "itemId" => "call-#{id}",
         "questions" => questions,
         "threadId" => "thread-malformed",
         "turnId" => "turn-malformed"
       }
     }}
  end

  defp expected_response(protocol, result) when result in ["allow", "allow_once"] do
    case protocol.name do
      name when name in [:command_execution, :file_change] ->
        %{"id" => protocol.request_id, "result" => %{"decision" => "accept"}}

      name when name in [:legacy_exec_command, :legacy_apply_patch] ->
        %{"id" => protocol.request_id, "result" => %{"decision" => "approved"}}

      :tool_approval ->
        %{
          "id" => protocol.request_id,
          "result" => %{
            "answers" => %{
              "mcp_tool_call_approval_call-95-a" => %{"answers" => ["Approve Once"]},
              "mcp_tool_call_approval_call-95-b" => %{"answers" => ["Approve Once"]}
            }
          }
        }

      :dynamic_tool_call ->
        failed_dynamic_tool_response(protocol.request_id, "extension authorization failed")
    end
  end

  defp expected_response(protocol, result) when result in ["deny", "error"] do
    case protocol.name do
      name when name in [:command_execution, :file_change] ->
        %{"id" => protocol.request_id, "result" => %{"decision" => "decline"}}

      name when name in [:legacy_exec_command, :legacy_apply_patch] ->
        %{"id" => protocol.request_id, "result" => %{"decision" => "denied"}}

      :tool_approval ->
        %{
          "id" => protocol.request_id,
          "result" => %{
            "answers" => %{
              "mcp_tool_call_approval_call-95-a" => %{"answers" => ["Deny"]},
              "mcp_tool_call_approval_call-95-b" => %{"answers" => ["Deny"]}
            }
          }
        }

      :dynamic_tool_call ->
        output =
          if result == "deny",
            do: "extension authorization denied",
            else: "extension authorization failed"

        %{
          "id" => protocol.request_id,
          "result" => %{
            "success" => false,
            "output" => output,
            "contentItems" => [%{"type" => "inputText", "text" => output}]
          }
        }
    end
  end

  defp invalid_intent_response(%{family: family, request_id: request_id})
       when family in [:command_execution, :file_change] do
    %{"id" => request_id, "result" => %{"decision" => "decline"}}
  end

  defp invalid_intent_response(%{family: family, request_id: request_id})
       when family in [:legacy_exec_command, :legacy_apply_patch] do
    %{"id" => request_id, "result" => %{"decision" => "denied"}}
  end

  defp invalid_intent_response(%{family: :dynamic_tool_call, request_id: request_id}) do
    failed_dynamic_tool_response(request_id, "extension authorization failed")
  end

  defp invalid_intent_response(%{family: :tool_approval, request_id: request_id}) do
    request_id
    |> then(&%{protocol_case(:tool_approval) | request_id: &1})
    |> expected_response("deny")
  end

  defp failed_dynamic_tool_response(request_id, output) do
    %{
      "id" => request_id,
      "result" => %{
        "success" => false,
        "output" => output,
        "contentItems" => [%{"type" => "inputText", "text" => output}]
      }
    }
  end

  defp assert_closed_intent(intent, protocol) do
    assert canonical_term(intent) == %{
             __struct__: SymphonyElixir.Extensions.CommandIntent,
             operation: Map.put(protocol.expected_operation, :__struct__, protocol.operation_module),
             request_id: protocol.request_id
           }
  end

  defp canonical_term(%{__struct__: module} = struct) do
    struct
    |> Map.from_struct()
    |> canonical_term()
    |> Map.put(:__struct__, module)
  end

  defp canonical_term(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, canonical_term(nested)} end)
  end

  defp canonical_term(value) when is_list(value), do: Enum.map(value, &canonical_term/1)
  defp canonical_term(value), do: value

  defp subscriber(test_pid) do
    fn message -> send(test_pid, {:oxe13_subscriber_capture, message}) end
  end

  defp drain_subscriber_messages(acc \\ []) do
    receive do
      {:oxe13_subscriber_capture, message} -> drain_subscriber_messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_authorization_events(events, protocol, result, fixture) do
    expected =
      cond do
        result == "deny" ->
          {:authorization_denied, :extension_authorization_denied}

        result == "error" ->
          {:authorization_failed, :extension_authorization_failed}

        protocol.name == :dynamic_tool_call and result in ["allow", "allow_once"] ->
          {:authorization_failed, :extension_authorization_failed}

        true ->
          nil
      end

    assert_exact_authorization_events(events, expected, protocol.request_id, elem(protocol.request, 0), fixture)
  end

  defp assert_invalid_authorization_event(events, test_case, fixture) do
    assert_exact_authorization_events(
      events,
      {:authorization_invalid, :command_intent_invalid},
      test_case.request_id,
      test_case.method,
      fixture
    )
  end

  defp assert_exact_authorization_events(events, expected, request_id, method, fixture) do
    authorization_events =
      Enum.filter(events, &(&1.event in [:authorization_denied, :authorization_failed, :authorization_invalid]))

    case expected do
      nil ->
        assert authorization_events == []

      {event_name, code} ->
        assert [event] = authorization_events

        assert Map.keys(event) |> Enum.sort() ==
                 [
                   :code,
                   :codex_app_server_pid,
                   :event,
                   :interface,
                   :method,
                   :request_id,
                   :timestamp
                 ]

        assert %DateTime{} = event.timestamp
        assert is_binary(event.codex_app_server_pid)

        assert Map.drop(event, [:timestamp, :codex_app_server_pid]) == %{
                 code: code,
                 event: event_name,
                 interface: :command_authorization,
                 method: method,
                 request_id: request_id
               }

        inspected = inspect(event, limit: :infinity, printable_limit: :infinity)

        for secret <- subscriber_secrets(fixture) do
          refute inspected =~ secret
        end
    end
  end

  defp assert_log_redacted(log, protocol, fixture, option_secret) do
    for secret <-
          [
            option_secret,
            "authorization-reason-do-not-log",
            "add-content-do-not-cross",
            "delete-content-do-not-cross",
            "diff-content-do-not-cross"
          ] ++ wire_secrets(protocol.request) do
      refute log =~ secret
    end

    refute log =~ fixture.issue.title
    refute log =~ fixture.issue.description
  end

  defp subscriber_secrets(fixture) do
    [
      fixture.issue.id,
      fixture.issue.identifier,
      fixture.issue.title,
      fixture.issue.description,
      fixture.workspace,
      "adapter-options-do-not-log",
      "decision-options-do-not-log",
      "malformed-options-do-not-log",
      "mismatch-options-do-not-log",
      "authorization-reason-do-not-log",
      "wire-do-not-leak",
      "turn_fixture"
    ]
  end

  defp wire_secrets({_method, payload}) do
    payload
    |> all_binary_values()
    |> Enum.filter(&String.contains?(&1, "do-not-leak"))
  end

  defp all_binary_values(value) when is_binary(value), do: [value]

  defp all_binary_values(value) when is_map(value) do
    Enum.flat_map(value, fn {key, nested} -> all_binary_values(key) ++ all_binary_values(nested) end)
  end

  defp all_binary_values(value) when is_list(value), do: Enum.flat_map(value, &all_binary_values/1)
  defp all_binary_values(_value), do: []

  defp setup_fake_turn!(suffix, flow, opts) do
    test_root = unique_root(suffix)
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "OXE-#{String.upcase(suffix)}")
    codex_binary = Path.join(test_root, "fake-codex")
    trace_file = Path.join(test_root, "client.trace")
    File.mkdir_p!(workspace)
    File.write!(codex_binary, fake_codex_script(flow, trace_file))
    File.chmod!(codex_binary, 0o755)
    on_exit(fn -> File.rm_rf(test_root) end)

    workflow_options = [
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    ]

    workflow_options =
      case Keyword.get(opts, :approval_policy) do
        nil -> workflow_options
        policy -> Keyword.put(workflow_options, :codex_approval_policy, policy)
      end

    write_workflow_file!(Workflow.workflow_file_path(), workflow_options)

    configure_extensions!(
      Keyword.get(opts, :options, %{}),
      authorization: Keyword.get(opts, :authorization, "turn_fixture")
    )

    %{
      workspace: workspace,
      trace_file: trace_file,
      issue: issue("turn-#{suffix}", "OXE-#{String.upcase(suffix)}")
    }
  end

  defp fake_codex_script(flow, trace_file) do
    """
    #!/bin/sh
    trace_file="#{trace_file}"
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\n' "$line" >> "$trace_file"
      case "$count" in
        1) printf '%s\n' '{"id":1,"result":{}}' ;;
        2) ;;
        3) printf '%s\n' '#{thread_start_response(flow)}' ;;
        #{turn_flow(flow)}
        *) exit 0 ;;
      esac
    done
    """
  end

  defp thread_start_response(:invalid_thread_id),
    do: ~s({"id":2,"result":{"thread":{"id":null}}})

  defp thread_start_response(_flow),
    do: ~s({"id":2,"result":{"thread":{"id":"thread-protocol"}}})

  defp turn_flow({method, payload}) do
    request = payload |> Map.put("method", method) |> Jason.encode!()

    missing_id_completion =
      if Map.has_key?(payload, "id") do
        ""
      else
        "printf '%s\\n' '{\"method\":\"turn/completed\"}'"
      end

    """
    4)
      printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-protocol"}}}'
      printf '%s\n' '#{request}'
      #{missing_id_completion}
      ;;
    5)
      printf '%s\n' '{"method":"turn/completed"}'
      exit 0
      ;;
    """
  end

  defp turn_flow(:invalid_turn_id) do
    """
    4)
      printf '%s\n' '{"id":3,"result":{"turn":{"id":null}}}'
      printf '%s\n' '{"method":"turn/completed"}'
      ;;
    """
  end

  defp turn_flow(:invalid_thread_id), do: ""

  defp turn_flow(:recursive) do
    {command_method, command_payload} = protocol_case(:command_execution).request
    {file_method, file_payload} = protocol_case(:file_change).request
    command_request = command_payload |> Map.put("method", command_method) |> Jason.encode!()
    file_request = file_payload |> Map.put("method", file_method) |> Jason.encode!()

    """
    4)
      printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-protocol"}}}'
      printf '%s' '{"method":"item/updated","params":{"padding":"'
      head -c #{@split_line_bytes} /dev/zero | tr '\\000' 'x'
      printf '%s\n' '"}}'
      printf '%s\n' '{"method":"future/unknown","params":{"value":"ignored"}}'
      printf '%s\n' '#{command_request}'
      ;;
    5)
      printf '%s\n' '#{file_request}'
      ;;
    6)
      printf '%s\n' '{"method":"turn/completed"}'
      exit 0
      ;;
    """
  end

  defp configure_extensions!(options, overrides \\ []) do
    path = Workflow.workflow_file_path()
    source = File.read!(path)
    authorization = Keyword.get(overrides, :authorization, "turn_fixture")

    stanza = """
    extensions:
      dispatch_admission: noop
      delivery_controller: noop
      command_authorization: #{authorization}
      observers: [noop]
      options: #{Jason.encode!(options)}
    """

    File.write!(path, String.replace(source, "---\n", "---\n#{stanza}", global: false))
    assert :ok = WorkflowStore.force_reload()
  end

  defp configure_extension_options!(options) do
    replace_extension_line!(~r/^  options: .*$/m, "  options: #{Jason.encode!(options)}")
  end

  defp configure_authorization!(selector) do
    replace_extension_line!(
      ~r/^  command_authorization: .*$/m,
      "  command_authorization: #{selector}"
    )
  end

  defp replace_extension_line!(pattern, replacement) do
    path = Workflow.workflow_file_path()
    source = File.read!(path)
    updated = Regex.replace(pattern, source, replacement, global: false)
    refute updated == source
    File.write!(path, updated)
    assert :ok = WorkflowStore.force_reload()
  end

  defp response_for(trace_file, request_id) do
    trace_file
    |> client_payloads()
    |> Enum.find(&(&1["id"] == request_id))
  end

  defp client_payloads(trace_file) do
    if File.exists?(trace_file) do
      trace_file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "JSON:"))
      |> Enum.map(&(&1 |> String.trim_leading("JSON:") |> Jason.decode!()))
    else
      []
    end
  end

  defp result_class({:error, {:turn_input_required, _payload}}), do: :turn_input_required
  defp result_class({:error, {:approval_required, _payload}}), do: :approval_required
  defp result_class({:ok, _result}), do: :completed
  defp result_class(other), do: {:unexpected, other}

  defp call(function, arguments), do: apply(Extensions, function, arguments)

  defp issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "private title #{identifier} do-not-log",
      description: "private description #{id} do-not-log",
      state: "In Progress",
      url: "https://example.invalid/#{identifier}",
      labels: [],
      dispatchable: true
    }
  end

  defp next_message(timeout \\ 1_000) do
    receive do
      message -> message
    after
      timeout -> flunk("expected the next OXE-1.3 message within #{timeout}ms")
    end
  end

  defp unique_root(suffix) do
    Path.join(
      System.tmp_dir!(),
      "symphony-oxe13-#{suffix}-#{System.unique_integer([:positive, :monotonic])}"
    )
  end

  defp reset_registry! do
    if function_exported?(ExtensionRegistry, :reset_for_test, 0) do
      ExtensionRegistry.reset_for_test()
    else
      :ok
    end
  end

  defp shutdown_task(%Task{pid: pid} = task) do
    if Process.alive?(pid), do: Task.shutdown(task, :brutal_kill)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
