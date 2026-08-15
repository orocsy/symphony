defmodule SymphonyElixir.ExtensionsAdmissionDeliveryRedTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ExtensionRegistry
  alias SymphonyElixir.Extensions
  alias SymphonyElixir.Extensions.ControllerFailure
  alias SymphonyElixir.Extensions.ExtensionFailure

  @fixture_recipient :oxe12_extension_fixture_recipient
  @orchestrator_name Module.concat(__MODULE__, Orchestrator)

  setup do
    reset_registry!()
    refute Process.whereis(@fixture_recipient)
    Process.register(self(), @fixture_recipient)

    on_exit(fn ->
      reset_registry!()
    end)

    :ok
  end

  test "facade constructs the admission context with a fresh options snapshot" do
    configure_extensions!("lifecycle_fixture", "noop", %{"marker" => "first"})
    issue = issue("context-admission", "OXE-CTX-ADMISSION")

    assert :kernel_default == Extensions.evaluate_admission(issue, 2)
    assert_receive {:oxe12_admission, ^issue, context}

    assert struct_module(context) == SymphonyElixir.Extensions.AdmissionContext
    assert context.attempt == 2
    assert context.options == %{"marker" => "first"}
    assert {:ok, registry} = ExtensionRegistry.current()
    assert context.registry_revision == registry.revision

    configure_extensions!("lifecycle_fixture", "noop", %{"marker" => "reloaded"})

    for {attempt, normalized} <- [{nil, 0}, {0, 0}, {-1, 0}] do
      assert :kernel_default == Extensions.evaluate_admission(issue, attempt)
      assert_receive {:oxe12_admission, ^issue, reloaded}
      assert struct_module(reloaded) == SymphonyElixir.Extensions.AdmissionContext
      assert reloaded.attempt == normalized
      assert reloaded.options == %{"marker" => "reloaded"}
      assert reloaded.registry_revision == registry.revision
    end
  end

  test "facade constructs the workspace-ready event and delivery context" do
    configure_extensions!("noop", "lifecycle_fixture", %{"marker" => "delivery"})
    issue = issue("context-delivery", "OXE-CTX-DELIVERY")
    workspace = Path.join(System.tmp_dir!(), "oxe-ctx-delivery")
    facts = {issue, workspace, "worker-a", 3}

    assert :kernel_default == Extensions.handle_delivery(:workspace_ready, facts)
    assert_receive {:oxe12_delivery, event, context}

    assert struct_module(event) == SymphonyElixir.Extensions.DeliveryEvent
    assert event.type == :workspace_ready
    assert struct_module(context) == SymphonyElixir.Extensions.DeliveryContext
    assert context.issue == issue
    assert context.workspace == workspace
    assert context.worker_host == "worker-a"
    assert context.attempt == 3
    assert context.options == %{"marker" => "delivery"}
    assert {:ok, registry} = ExtensionRegistry.current()
    assert context.registry_revision == registry.revision

    nil_host_facts = {issue, workspace, nil, nil}
    assert :kernel_default == Extensions.handle_delivery(:workspace_ready, nil_host_facts)
    assert_receive {:oxe12_delivery, nil_host_event, nil_host_context}
    assert nil_host_event.type == :workspace_ready
    assert nil_host_context.worker_host == nil
    assert nil_host_context.attempt == 0
    assert nil_host_context.registry_revision == registry.revision
  end

  test "facade rejects malformed kernel facts before locking the registry" do
    configure_extensions!("lifecycle_fixture", "lifecycle_fixture", %{})
    issue = issue("invalid-facts", "OXE-INVALID-FACTS")
    workspace = "/tmp/invalid"

    assert {:error,
            %ExtensionFailure{
              code: :invalid_kernel_input,
              interface: :dispatch_admission,
              adapter: nil,
              registry_revision: nil,
              reason: :attempt_invalid
            }} = Extensions.evaluate_admission(issue, %{})

    invalid_delivery_inputs = [
      {:unknown_event, {issue, workspace, nil, 0}},
      {:workspace_ready, {issue, workspace, nil}},
      {:workspace_ready, {issue, workspace, nil, 0, :extra}},
      {:workspace_ready, %{}},
      {:workspace_ready, {:not_an_issue, workspace, nil, 0}},
      {:workspace_ready, {issue, 123, nil, 0}},
      {:workspace_ready, {issue, workspace, 123, 0}},
      {:workspace_ready, {issue, workspace, nil, %{}}}
    ]

    for {event, facts} <- invalid_delivery_inputs do
      assert {:error,
              %ControllerFailure{
                code: :invalid_kernel_input,
                interface: :delivery_controller,
                adapter: nil,
                registry_revision: nil,
                reason: :workspace_ready_facts_invalid
              }, []} = Extensions.handle_delivery(event, facts)
    end

    assert {:error, %ExtensionFailure{code: :extension_registry_unavailable}} =
             ExtensionRegistry.current()

    refute_receive {:oxe12_admission, _, _}
    refute_receive {:oxe12_delivery, _, _}
  end

  test "admission rejection occurs before worker selection, claim, task, or workspace" do
    assert_admission_blocks("reject", "admission-rejection", "OXE-ADMISSION-REJECT")
  end

  test "admission failure occurs before worker selection, claim, task, or workspace" do
    assert_admission_blocks("error", "admission-error", "OXE-ADMISSION-ERROR")
  end

  test "no-op admission preserves the current dispatch and claim observation" do
    assert_admission_dispatches("noop", nil, "admission-noop", "OXE-ADMISSION-NOOP")
  end

  test "explicit admission preserves the current dispatch and claim observation" do
    assert_admission_dispatches(
      "lifecycle_fixture",
      "admit",
      "admission-admit",
      "OXE-ADMISSION-ADMIT"
    )
  end

  test "delivery failure preserves workspace and precedes before-run and Codex" do
    assert_delivery_stops("error", "delivery-failure", "OXE-DELIVERY-FAIL")
  end

  test "delivery decision is surfaced without entering before-run or Codex" do
    assert_delivery_stops("decision", "delivery-decision", "OXE-DELIVERY-DECISION")
  end

  test "no-op delivery preserves the current before-run outcome" do
    test_root = unique_root("delivery-noop")
    workspace_root = Path.join(test_root, "workspaces")
    marker = Path.join(test_root, "before-run")
    on_exit(fn -> File.rm_rf(test_root) end)

    configure_extensions!(
      "noop",
      "noop",
      %{},
      workspace_root: workspace_root,
      hook_before_run: ": > \"#{marker}\"; exit 1"
    )

    issue = issue("delivery-noop", "OXE-DELIVERY-NOOP")
    issue_id = issue.id
    parent = self()

    task =
      Task.async(fn ->
        try do
          AgentRunner.run(issue, parent, attempt: 5)
        rescue
          error in RuntimeError -> {:raised, Exception.message(error)}
        end
      end)

    assert {:worker_runtime_info, ^issue_id, %{worker_host: nil, workspace_path: workspace_path}} = next_message()

    assert {:raised, message} = Task.await(task, 1_000)
    assert message =~ "workspace_hook_failed"
    assert message =~ "before_run"

    assert File.exists?(marker)

    assert {:ok, expected_workspace} =
             SymphonyElixir.PathSafety.canonicalize(Path.join(workspace_root, issue.identifier))

    assert workspace_path == expected_workspace
    assert File.dir?(workspace_path)
  end

  defp assert_admission_blocks(result, id, identifier) do
    stop_default_runtime!()
    test_root = unique_root(id)
    workspace_root = Path.join(test_root, "workspaces")
    initial_issue = issue(id, identifier)
    refreshed_issue = %{initial_issue | title: "refreshed secret title do-not-log"}

    configure_extensions!(
      "lifecycle_fixture",
      "noop",
      %{"admission_result" => result, "secret" => "options-do-not-log"},
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 60_000,
      hook_before_run: "exit 1"
    )

    Application.put_env(
      :symphony_elixir,
      :memory_tracker_issues,
      issue_refresh_stream(initial_issue, refreshed_issue)
    )

    trace_new_worker_selection_calls!()

    log =
      capture_log(fn ->
        {task_supervisor, orchestrator} = start_runtime!(test_root)

        assert_receive {:trace, ^orchestrator, :call, {Orchestrator, :select_worker_host, [_state, nil]}},
                       1_000

        assert_receive {:oxe12_admission, ^refreshed_issue, context}, 1_000
        assert context.attempt == 0

        refute_receive {:trace, ^orchestrator, :call, {Orchestrator, :select_worker_host, [_state, nil]}},
                       50

        assert Task.Supervisor.children(task_supervisor) == []

        state = :sys.get_state(orchestrator)
        assert state.running == %{}
        assert state.claimed == MapSet.new()
        assert state.retry_attempts == %{}
        refute File.exists?(Path.join(workspace_root, refreshed_issue.identifier))
      end)

    assert_admission_log(result, log, refreshed_issue)
  end

  defp assert_admission_log("error", log, issue) do
    assert log =~ "extension admission failed"
    assert log =~ "code=fixture_admission_failed"
    assert log =~ "interface=dispatch_admission"
    refute log =~ issue.title
    refute log =~ "options-do-not-log"
  end

  defp assert_admission_log("reject", _log, _issue), do: :ok

  defp assert_admission_dispatches(selector, result, id, identifier) do
    stop_default_runtime!()
    test_root = unique_root(id)
    workspace_root = Path.join(test_root, "workspaces")
    marker = Path.join(test_root, "before-run")
    fifo = Path.join(test_root, "before-run-fifo")
    options = if result, do: %{"admission_result" => result}, else: %{}

    configure_extensions!(
      selector,
      "noop",
      options,
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 60_000,
      hook_before_run: "mkfifo \"#{fifo}\"; : > \"#{marker}\"; read _ < \"#{fifo}\"",
      hook_timeout_ms: 60_000
    )

    issue = issue(id, identifier)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    trace_new_worker_selection_calls!()
    {task_supervisor, orchestrator} = start_runtime!(test_root)

    assert_receive {:trace, ^orchestrator, :call, {Orchestrator, :select_worker_host, [_state, nil]}},
                   1_000

    if selector == "lifecycle_fixture" do
      assert_receive {:oxe12_admission, ^issue, context}, 1_000
      assert context.attempt == 0
    end

    assert_receive {:trace, ^orchestrator, :call, {Orchestrator, :select_worker_host, [_state, nil]}},
                   1_000

    assert eventually(fn -> File.exists?(marker) end)
    assert [_worker] = Task.Supervisor.children(task_supervisor)

    state = :sys.get_state(orchestrator)
    assert Map.has_key?(state.running, issue.id)
    assert MapSet.member?(state.claimed, issue.id)
    assert File.dir?(Path.join(workspace_root, issue.identifier))
  end

  defp assert_delivery_stops(result, id, identifier) do
    test_root = unique_root(id)
    workspace_root = Path.join(test_root, "workspaces")
    marker = Path.join(test_root, "before-run")
    on_exit(fn -> File.rm_rf(test_root) end)

    configure_extensions!(
      "noop",
      "lifecycle_fixture",
      %{"delivery_result" => result},
      workspace_root: workspace_root,
      hook_before_run: ": > \"#{marker}\"",
      codex_command: "false"
    )

    issue = issue(id, identifier)
    issue_id = issue.id
    parent = self()

    task =
      Task.async(fn ->
        try do
          AgentRunner.run(issue, parent, attempt: 4)
        rescue
          error in RuntimeError -> {:raised, Exception.message(error)}
        end
      end)

    assert {:worker_runtime_info, ^issue_id, %{worker_host: nil, workspace_path: workspace_path}} = next_message()

    assert {:oxe12_delivery, event, context} = next_message()
    assert event.type == :workspace_ready
    assert context.issue == issue
    assert context.workspace == workspace_path
    assert context.attempt == 4
    assert File.dir?(workspace_path)
    refute File.exists?(marker)

    assert {:raised, message} = Task.await(task, 1_000)
    reason = expected_delivery_reason(result, context)

    assert message ==
             "Agent run failed for issue_id=#{issue.id} " <>
               "issue_identifier=#{issue.identifier}: #{inspect(reason)}"
  end

  defp expected_delivery_reason("error", context) do
    failure = %ControllerFailure{
      code: :fixture_delivery_stopped,
      interface: :delivery_controller,
      adapter: SymphonyElixir.ExtensionLifecycleFixtures.DeliveryController,
      registry_revision: context.registry_revision,
      reason: :fixture_requested
    }

    {:extension_delivery_failed, failure, []}
  end

  defp expected_delivery_reason("decision", _context) do
    {:extension_delivery_decision, :fixture_park, [%{type: :fixture_evidence}]}
  end

  defp configure_extensions!(admission, delivery, options, overrides \\ []) do
    path = Workflow.workflow_file_path()
    write_workflow_file!(path, overrides)
    source = File.read!(path)

    stanza = """
    extensions:
      dispatch_admission: #{admission}
      delivery_controller: #{delivery}
      command_authorization: noop
      observers: [noop]
      options: #{Jason.encode!(options)}
    """

    File.write!(path, String.replace(source, "---\n", "---\n#{stanza}", global: false))
    assert :ok = WorkflowStore.force_reload()
  end

  defp issue_refresh_stream(initial_issue, refreshed_issue) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> stop_if_alive(counter) end)

    Stream.map([:issue], fn :issue ->
      call = Agent.get_and_update(counter, &{&1, &1 + 1})
      if call < 2, do: initial_issue, else: refreshed_issue
    end)
  end

  defp trace_new_worker_selection_calls! do
    :erlang.trace_pattern({Orchestrator, :select_worker_host, 2}, true, [:local])
    :erlang.trace(:new, true, [:call])

    on_exit(fn ->
      :erlang.trace(:new, false, [:call])
      :erlang.trace_pattern({Orchestrator, :select_worker_host, 2}, false, [:local])
    end)
  end

  defp start_runtime!(test_root) do
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    {:ok, orchestrator} =
      Orchestrator.start_link(name: @orchestrator_name, task_supervisor: task_supervisor)

    on_exit(fn ->
      stop_if_alive(orchestrator)
      stop_if_alive(task_supervisor)
      File.rm_rf(test_root)
    end)

    {task_supervisor, orchestrator}
  end

  defp next_message(timeout \\ 1_000) do
    receive do
      message -> message
    after
      timeout -> flunk("expected the next lifecycle message within #{timeout}ms")
    end
  end

  defp issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "OXE-1.2 lifecycle fixture",
      description: "Define the admission and workspace-ready seams",
      state: "In Progress",
      url: "https://example.invalid/#{identifier}",
      labels: [],
      dispatchable: true
    }
  end

  defp struct_module(value) when is_map(value), do: Map.get(value, :__struct__)
  defp struct_module(_value), do: nil

  defp unique_root(suffix) do
    Path.join(
      System.tmp_dir!(),
      "symphony-oxe12-#{suffix}-#{System.unique_integer([:positive, :monotonic])}"
    )
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp stop_default_runtime! do
    case Enum.find(Supervisor.which_children(SymphonyElixir.Supervisor), fn
           {SymphonyElixir.AgentRuntimeSupervisor, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {SymphonyElixir.AgentRuntimeSupervisor, _pid, _type, _modules} ->
        assert :ok =
                 Supervisor.terminate_child(
                   SymphonyElixir.Supervisor,
                   SymphonyElixir.AgentRuntimeSupervisor
                 )

        on_exit(fn ->
          Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
          restart_default_runtime!()
        end)

      _other ->
        :ok
    end
  end

  defp restart_default_runtime! do
    case Supervisor.restart_child(
           SymphonyElixir.Supervisor,
           SymphonyElixir.AgentRuntimeSupervisor
         ) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
    end
  end

  defp stop_if_alive(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp reset_registry! do
    if function_exported?(ExtensionRegistry, :reset_for_test, 0) do
      ExtensionRegistry.reset_for_test()
    else
      :ok
    end
  end
end
