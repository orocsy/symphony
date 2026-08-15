defmodule SymphonyElixir.ExtensionsAdmissionDeliveryRedTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ExtensionRegistry
  alias SymphonyElixir.Extensions

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
    configure_extensions!("lifecycle_fixture", "noop", %{"marker" => "admission"})
    issue = issue("context-admission", "OXE-CTX-ADMISSION")

    assert :kernel_default == Extensions.evaluate_admission(issue, 2)
    assert_receive {:oxe12_admission, ^issue, context}

    assert struct_module(context) == SymphonyElixir.Extensions.AdmissionContext
    assert context.attempt == 2
    assert context.options == %{"marker" => "admission"}
    assert {:ok, registry} = ExtensionRegistry.current()
    assert context.registry_revision == registry.revision
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
  end

  test "admission rejection occurs before worker selection, claim, task, or workspace" do
    stop_default_runtime!()
    test_root = unique_root("admission-rejection")
    workspace_root = Path.join(test_root, "workspaces")

    configure_extensions!(
      "lifecycle_fixture",
      "noop",
      %{"admission_result" => "reject"},
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 60_000,
      hook_before_run: "exit 1"
    )

    issue = issue("admission-rejection", "OXE-ADMISSION-REJECT")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    {:ok, task_supervisor} = Task.Supervisor.start_link()

    {:ok, orchestrator} =
      Orchestrator.start_link(name: @orchestrator_name, task_supervisor: task_supervisor)

    on_exit(fn ->
      stop_if_alive(orchestrator)
      stop_if_alive(task_supervisor)
      File.rm_rf(test_root)
    end)

    assert_receive {:oxe12_admission, ^issue, context}, 1_000
    assert context.attempt == 0
    assert Task.Supervisor.children(task_supervisor) == []

    state = :sys.get_state(orchestrator)
    assert state.running == %{}
    assert state.claimed == MapSet.new()
    assert state.retry_attempts == %{}
    refute File.exists?(Path.join(workspace_root, issue.identifier))
  end

  test "no-op admission preserves the current dispatch and claim observation" do
    stop_default_runtime!()
    test_root = unique_root("admission-noop")
    workspace_root = Path.join(test_root, "workspaces")
    marker = Path.join(test_root, "before-run")
    fifo = Path.join(test_root, "before-run-fifo")

    configure_extensions!(
      "noop",
      "noop",
      %{},
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 60_000,
      hook_before_run: "mkfifo \"#{fifo}\"; : > \"#{marker}\"; read _ < \"#{fifo}\"",
      hook_timeout_ms: 60_000
    )

    issue = issue("admission-noop", "OXE-ADMISSION-NOOP")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    {:ok, task_supervisor} = Task.Supervisor.start_link()

    {:ok, orchestrator} =
      Orchestrator.start_link(name: @orchestrator_name, task_supervisor: task_supervisor)

    on_exit(fn ->
      stop_if_alive(orchestrator)
      stop_if_alive(task_supervisor)
      File.rm_rf(test_root)
    end)

    assert eventually(fn -> File.exists?(marker) end)
    assert [_worker] = Task.Supervisor.children(task_supervisor)

    state = :sys.get_state(orchestrator)
    assert Map.has_key?(state.running, issue.id)
    assert MapSet.member?(state.claimed, issue.id)
    assert File.dir?(Path.join(workspace_root, issue.identifier))
  end

  test "delivery failure preserves workspace and precedes before-run and Codex" do
    test_root = unique_root("delivery-failure")
    workspace_root = Path.join(test_root, "workspaces")
    marker = Path.join(test_root, "before-run")
    on_exit(fn -> File.rm_rf(test_root) end)

    configure_extensions!(
      "noop",
      "lifecycle_fixture",
      %{"delivery_result" => "error"},
      workspace_root: workspace_root,
      hook_before_run: ": > \"#{marker}\"",
      codex_command: "false"
    )

    issue = issue("delivery-failure", "OXE-DELIVERY-FAIL")

    task =
      Task.async(fn ->
        try do
          AgentRunner.run(issue, self(), attempt: 4)
        rescue
          error in RuntimeError -> {:raised, Exception.message(error)}
        end
      end)

    assert_receive {:oxe12_delivery, event, context}, 1_000
    assert event.type == :workspace_ready
    assert context.issue == issue
    assert context.attempt == 4
    assert File.dir?(context.workspace)
    refute File.exists?(marker)

    assert {:raised, message} = Task.await(task, 1_000)
    assert message =~ "fixture_delivery_stopped"
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

    assert_raise RuntimeError, ~r/workspace_hook_failed.*before_run/, fn ->
      AgentRunner.run(issue, nil, attempt: 5)
    end

    assert File.exists?(marker)
    assert File.dir?(Path.join(workspace_root, issue.identifier))
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
