defmodule SymphonyElixir.ExtensionsObserverDispatchRedTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ExtensionRegistry
  alias SymphonyElixir.Extensions

  @fixture_recipient :oxe13a_extension_observer_fixture_recipient
  @dispatcher SymphonyElixir.Extensions.ObserverDispatcher
  @queue_capacity 64

  setup do
    drain_dispatcher_if_available(0)
    reset_registry!()
    refute Process.whereis(@fixture_recipient)
    Process.register(self(), @fixture_recipient)

    on_exit(fn ->
      drain_dispatcher_if_available(0)
      reset_registry!()
    end)

    :ok
  end

  test "no-op observer preserves the exact AppServer result and subscriber sequence" do
    fixture = setup_fake_turn!("noop-baseline", ["noop"])
    test_pid = self()

    assert {:ok, %{thread_id: "thread-observer", turn_id: "turn-observer"}} =
             AppServer.run(fixture.workspace, "observer no-op baseline", fixture.issue, on_message: subscriber(test_pid))

    assert Enum.map(drain_subscriber_messages(), & &1.event) == [
             :session_started,
             :notification,
             :turn_completed
           ]

    refute_receive {:oxe13a_observer, _}
    refute Process.whereis(@dispatcher)
  end

  test "no-op facade returns the original subscriber function unchanged" do
    context =
      "noop-identity"
      |> observer_issue("OXE-OBSERVER-NOOP-IDENTITY")
      |> turn_context!(["noop"])

    subscriber = fn _message -> :ok end
    assert subscriber === call(:observe_turn, [context, subscriber])
    refute Process.whereis(@dispatcher)
  end

  test "blocked dispatcher initialization returns a subscriber-neutral loss wrapper within budget" do
    current_issue = observer_issue("init-blocked", "OXE-OBSERVER-INIT-BLOCKED")
    context = turn_context!(current_issue, ["observer_fixture"])
    test_pid = self()
    task_supervisor = Process.whereis(SymphonyElixir.TaskSupervisor)
    message = observer_message(:notification, 1)

    assert :ok == :sys.suspend(task_supervisor)

    try do
      {probe, probe_monitor} =
        spawn_monitor(fn ->
          observed = observed_subscriber(context, test_pid)
          send(test_pid, {:oxe13a_observe_turn_ready, self(), observed})
        end)

      assert_receive {:oxe13a_observe_turn_ready, ^probe, observed}, 100
      assert_receive {:DOWN, ^probe_monitor, :process, ^probe, :normal}

      log =
        capture_log(fn ->
          assert :ok == observed.(message)
          assert_receive {:oxe13a_subscriber, ^message}
        end)

      dropped_event_id =
        event_id(
          current_issue.id,
          context.thread_id,
          context.turn_id,
          1,
          "codex.notification"
        )

      assert delivery_failure_log_bodies(log) == [
               "telemetry.delivery_failed first_event_id=#{dropped_event_id} last_event_id=#{dropped_event_id} class=dispatcher_unavailable"
             ]

      refute_receive {:oxe13a_observer, _envelope}
      refute Process.whereis(@dispatcher)
    after
      :ok = :sys.resume(task_supervisor)
    end

    _children = Task.Supervisor.children(task_supervisor)
    refute Process.whereis(@dispatcher)
  end

  test "direct record rejects malformed envelopes without adapter dispatch or secret leakage" do
    configure_extensions!(["observer_fixture"])
    malformed = %{raw: "malformed-observer-envelope-do-not-log"}

    log =
      capture_log(fn ->
        assert :ok == Extensions.record(malformed)
      end)

    assert delivery_failure_log_bodies(log) == ["telemetry.delivery_failed class=invalid_envelope"]
    refute_receive {:oxe13a_observer, _envelope}
    refute log =~ "malformed-observer-envelope-do-not-log"
    refute Process.whereis(@dispatcher)
  end

  test "AppServer active observation adds envelopes without changing subscriber messages" do
    fixture = setup_fake_turn!("active-hook", ["observer_fixture"])
    test_pid = self()

    assert {:ok, _result} =
             AppServer.run(fixture.workspace, "observer active hook", fixture.issue, on_message: subscriber(test_pid))

    subscriber_messages = drain_subscriber_messages()

    assert Enum.map(subscriber_messages, & &1.event) == [
             :session_started,
             :notification,
             :turn_completed
           ]

    envelopes = receive_observer_envelopes(3)
    assert :ok == drain_dispatcher!(1_000)

    assert Enum.map(envelopes, & &1.event_type) == [
             "codex.session_started",
             "codex.notification",
             "codex.turn_completed"
           ]

    assert Enum.map(envelopes, & &1.turn_id) == List.duplicate("turn-observer", 3)
    assert Enum.map(envelopes, & &1.sequence) == [1, 2, 3]
    assert Enum.map(subscriber_messages, & &1.timestamp) == Enum.map(envelopes, & &1.emitted_at)
  end

  test "envelope is closed, correlated, usage-normalized, and secret-free" do
    current_issue = observer_issue("closed-envelope", "OXE-OBSERVER-CLOSED")
    context = turn_context!(current_issue, ["observer_fixture"])
    test_pid = self()
    observed = observed_subscriber(context, test_pid)
    emitted_at = ~U[2026-08-16 00:00:00Z]

    message = %{
      event: :authorization_denied,
      timestamp: emitted_at,
      method: "item/commandExecution/requestApproval",
      request_id: 701,
      usage: %{
        "input_tokens" => 11,
        "cached_input_tokens" => 3,
        "output_tokens" => 5,
        "total_tokens" => 16,
        "secret_usage" => "usage-do-not-cross"
      },
      payload: %{"secret" => "payload-do-not-cross"},
      raw: "raw-do-not-cross",
      reason: %{secret: "reason-do-not-cross"}
    }

    assert :ok == observed.(message)
    assert_receive {:oxe13a_subscriber, ^message}
    assert_receive {:oxe13a_observer, envelope}

    expected_event_id =
      event_id(
        current_issue.id,
        context.thread_id,
        context.turn_id,
        1,
        "codex.authorization_denied"
      )

    canonical = canonical_term(envelope)

    assert canonical == %{
             __struct__: SymphonyElixir.Extensions.ObserverEnvelope,
             schema_version: 1,
             event_id: expected_event_id,
             sequence: 1,
             emitted_at: emitted_at,
             source: :codex_app_server,
             event_type: "codex.authorization_denied",
             issue_id: current_issue.id,
             issue_identifier: current_issue.identifier,
             issue_revision: "sha256:" <> sha256(current_issue.description),
             run_id: "run_" <> sha256(context.thread_id),
             attempt_id: nil,
             turn_id: context.turn_id,
             miu_id: nil,
             transition_id: nil,
             decision_id:
               "decision_" <>
                 sha256(Jason.encode!([expected_event_id, "authorization", "denied", nil])),
             operation_fingerprint:
               "sha256:" <>
                 sha256(Jason.encode!(["item/commandExecution/requestApproval", 701])),
             decision: %{
               __struct__: SymphonyElixir.Extensions.ObserverDecision,
               type: :authorization,
               class: :denied,
               wake_condition: nil
             },
             usage: %{
               __struct__: SymphonyElixir.Extensions.ObserverUsage,
               input_tokens: 11,
               cached_input_tokens: 3,
               output_tokens: 5,
               total_tokens: 16
             },
             evidence_refs: []
           }

    inspected = inspect(envelope, limit: :infinity, printable_limit: :infinity)

    for secret <- [
          current_issue.title,
          current_issue.description,
          current_issue.url,
          context.workspace,
          "usage-do-not-cross",
          "payload-do-not-cross",
          "raw-do-not-cross",
          "reason-do-not-cross"
        ] do
      refute inspected =~ secret
    end
  end

  test "hung observer cannot delay the subscriber or another observer" do
    context =
      "hung"
      |> observer_issue("OXE-OBSERVER-HUNG")
      |> turn_context!(["observer_hanging", "observer_fixture"])

    test_pid = self()
    observed = observed_subscriber(context, test_pid)
    message = observer_message(:notification, 1)

    assert :ok == observed.(message)
    assert_receive {:oxe13a_subscriber, ^message}
    assert_receive {:oxe13a_observer_hanging, hanging_pid, envelope}
    assert_receive {:oxe13a_observer, same_envelope}
    assert canonical_term(same_envelope) == canonical_term(envelope)
    assert Process.alive?(hanging_pid)

    hanging_monitor = Process.monitor(hanging_pid)

    log =
      capture_log(fn ->
        assert :ok == drain_dispatcher!(1_000)
      end)

    assert_receive {:DOWN, ^hanging_monitor, :process, ^hanging_pid, _reason}

    assert observer_failure_log_bodies(log) == [
             observer_failure_line(
               envelope.event_id,
               SymphonyElixir.ExtensionObserverFixtures.HangingObserver,
               context.registry_revision,
               :timeout
             )
           ]

    refute log =~ inspect(message)
  end

  test "queue capacity drops excess envelopes with sanitized evidence only" do
    current_issue = observer_issue("full", "OXE-OBSERVER-FULL")
    context = turn_context!(current_issue, ["observer_hanging"])
    test_pid = self()
    observed = observed_subscriber(context, test_pid)
    first = observer_message(:notification, 1)

    assert :ok == observed.(first)
    assert_receive {:oxe13a_observer_hanging, _hanging_pid, _envelope}

    log =
      capture_log(fn ->
        for sequence <- 2..(@queue_capacity + 2) do
          assert :ok == observed.(observer_message(:notification, sequence))
        end
      end)

    assert length(drain_subscriber_messages()) == @queue_capacity + 2

    dropped_ids =
      for sequence <- (@queue_capacity + 1)..(@queue_capacity + 2) do
        event_id(
          current_issue.id,
          context.thread_id,
          context.turn_id,
          sequence,
          "codex.notification"
        )
      end

    loss_lines =
      log
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.contains?(&1, "telemetry.delivery_failed"))

    assert Enum.map(loss_lines, &fixed_log_body/1) ==
             Enum.map(dropped_ids, fn event_id ->
               "telemetry.delivery_failed first_event_id=#{event_id} last_event_id=#{event_id} class=queue_full"
             end)

    for secret <- [
          current_issue.title,
          current_issue.description,
          current_issue.url,
          context.workspace,
          inspect(first)
        ] do
      refute log =~ secret
    end
  end

  test "observer return and process failures are classified while fan-out continues" do
    observers = [
      "observer_error",
      "observer_wrong_interface",
      "observer_malformed",
      "raising",
      "observer_throwing",
      "observer_exiting",
      "observer_killing",
      "observer_fixture"
    ]

    context =
      "failure-matrix"
      |> observer_issue("OXE-OBSERVER-FAILURES")
      |> turn_context!(observers)

    test_pid = self()
    observed = observed_subscriber(context, test_pid)
    message = observer_message(:notification, 1)

    {envelope, log} =
      with_log(fn ->
        assert :ok == observed.(message)
        assert_receive {:oxe13a_subscriber, ^message}
        assert_receive {:oxe13a_observer, envelope}
        assert :ok == drain_dispatcher!(1_000)
        assert String.starts_with?(envelope.event_id, "evt_")
        envelope
      end)

    expected_failure_lines =
      [
        {SymphonyElixir.ExtensionObserverFixtures.ErrorObserver, :adapter_error},
        {SymphonyElixir.ExtensionObserverFixtures.WrongInterfaceObserver, :invalid_adapter_return},
        {SymphonyElixir.ExtensionObserverFixtures.MalformedObserver, :invalid_adapter_return},
        {SymphonyElixir.ExtensionHostFixtures.RaisingObserver, :raise},
        {SymphonyElixir.ExtensionObserverFixtures.ThrowingObserver, :throw},
        {SymphonyElixir.ExtensionObserverFixtures.ExitingObserver, :exit},
        {SymphonyElixir.ExtensionObserverFixtures.KillingObserver, :killed}
      ]
      |> Enum.map(fn {adapter, class} ->
        observer_failure_line(envelope.event_id, adapter, context.registry_revision, class)
      end)
      |> Enum.sort()

    assert Enum.sort(observer_failure_log_bodies(log)) == expected_failure_lines

    for secret <- [
          "observer-error-reason-do-not-log",
          "observer-malformed-do-not-log",
          "observer-wrong-interface-do-not-log",
          "observer token=do-not-log",
          "observer-throw-reason-do-not-log",
          "observer-exit-reason-do-not-log",
          inspect(message)
        ] do
      refute log =~ secret
    end
  end

  test "dispatcher crash replays the accepted ledger event with the same id" do
    context =
      "restart"
      |> observer_issue("OXE-OBSERVER-RESTART")
      |> turn_context!(["observer_hanging", "observer_fixture"])

    observed = observed_subscriber(context, self())
    assert :ok == observed.(observer_message(:notification, 1))
    assert_receive {:oxe13a_observer_hanging, first_task, first_envelope}
    assert_receive {:oxe13a_observer, first_copy}
    assert first_copy.event_id == first_envelope.event_id
    task_monitor = Process.monitor(first_task)

    dispatcher = Process.whereis(@dispatcher)
    assert is_pid(dispatcher)
    monitor = Process.monitor(dispatcher)
    Process.exit(dispatcher, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^dispatcher, :killed}
    assert_receive {:DOWN, ^task_monitor, :process, ^first_task, _reason}

    assert_receive {:oxe13a_observer_hanging, replay_task, replay_envelope}, 1_000
    assert_receive {:oxe13a_observer, replay_copy}, 1_000
    assert replay_envelope.event_id == first_envelope.event_id
    assert replay_copy.event_id == first_envelope.event_id

    send(replay_task, :oxe13a_continue)
    assert :ok == drain_dispatcher!(1_000)
  end

  test "drain deadline contains tasks, logs its bounded range, and closes ingress" do
    current_issue = observer_issue("drain", "OXE-OBSERVER-DRAIN")
    context = turn_context!(current_issue, ["observer_hanging"])
    observed = observed_subscriber(context, self())
    message = observer_message(:notification, 1)

    assert :ok == observed.(message)
    assert_receive {:oxe13a_observer_hanging, hanging_pid, envelope}
    task_monitor = Process.monitor(hanging_pid)

    log =
      capture_log(fn ->
        assert {:error, :observer_drain_timeout} == drain_dispatcher!(0)
      end)

    assert_receive {:DOWN, ^task_monitor, :process, ^hanging_pid, _reason}
    refute Process.whereis(@dispatcher)

    assert fixed_log_body(log) ==
             "telemetry.delivery_failed first_event_id=#{envelope.event_id} last_event_id=#{envelope.event_id} class=drain_timeout"

    closed_log =
      capture_log(fn ->
        assert :ok == observed.(message)
        assert_receive {:oxe13a_subscriber, ^message}
      end)

    closed_event_id =
      event_id(
        current_issue.id,
        context.thread_id,
        context.turn_id,
        2,
        "codex.notification"
      )

    assert fixed_log_body(closed_log) ==
             "telemetry.delivery_failed first_event_id=#{closed_event_id} last_event_id=#{closed_event_id} class=dispatcher_draining"

    refute log =~ current_issue.description
    refute log =~ inspect(message)
  end

  test "successful drain delivers accepted work and a later turn starts fresh" do
    first_context =
      "drain-success"
      |> observer_issue("OXE-OBSERVER-DRAIN-SUCCESS")
      |> turn_context!(["observer_fixture"])

    first_observed = observed_subscriber(first_context, self())
    assert :ok == first_observed.(observer_message(:notification, 1))
    assert :ok == drain_dispatcher!(1_000)
    assert_receive {:oxe13a_observer, first_envelope}
    refute Process.whereis(@dispatcher)

    reset_registry!()

    second_context =
      "drain-fresh"
      |> observer_issue("OXE-OBSERVER-DRAIN-FRESH")
      |> turn_context!(["observer_fixture"])

    second_observed = observed_subscriber(second_context, self())
    assert :ok == second_observed.(observer_message(:notification, 1))
    assert_receive {:oxe13a_observer, second_envelope}
    refute first_envelope.event_id == second_envelope.event_id
    assert :ok == drain_dispatcher!(1_000)
  end

  test "runtime supervisor shutdown logs the accepted range before ledger loss" do
    context =
      "shutdown"
      |> observer_issue("OXE-OBSERVER-SHUTDOWN")
      |> turn_context!(["observer_hanging"])

    observed = observed_subscriber(context, self())
    assert :ok == observed.(observer_message(:notification, 1))
    assert_receive {:oxe13a_observer_hanging, _hanging_pid, envelope}

    on_exit(&restart_default_runtime!/0)

    log =
      capture_log(fn ->
        assert :ok =
                 Supervisor.terminate_child(
                   SymphonyElixir.Supervisor,
                   SymphonyElixir.AgentRuntimeSupervisor
                 )
      end)

    assert delivery_failure_log_bodies(log) == [
             "telemetry.delivery_failed first_event_id=#{envelope.event_id} last_event_id=#{envelope.event_id} class=shutdown"
           ]

    refute Process.whereis(@dispatcher)
    restart_default_runtime!()
  end

  defp observed_subscriber(context, test_pid) do
    call(:observe_turn, [context, fn message -> send(test_pid, {:oxe13a_subscriber, message}) end])
  end

  defp subscriber(test_pid) do
    fn message -> send(test_pid, {:oxe13a_subscriber_capture, message}) end
  end

  defp observer_message(event, sequence) do
    %{
      event: event,
      timestamp: DateTime.add(~U[2026-08-16 00:00:00Z], sequence, :second),
      payload: %{"secret" => "message-#{sequence}-do-not-cross"},
      raw: "raw-#{sequence}-do-not-cross"
    }
  end

  defp turn_context!(current_issue, observers) do
    configure_extensions!(observers)

    assert {:ok, seed} =
             call(:capture_turn, [
               {current_issue, "/tmp/#{current_issue.identifier}", nil, "thread-observer"}
             ])

    assert {:ok, context} = call(:bind_turn, [seed, "turn-observer"])
    context
  end

  defp configure_extensions!(observers) do
    path = Workflow.workflow_file_path()
    source = File.read!(path)

    stanza = """
    extensions:
      dispatch_admission: noop
      delivery_controller: noop
      command_authorization: noop
      observers: [#{Enum.join(observers, ", ")}]
      options: {}
    """

    File.write!(path, String.replace(source, "---\n", "---\n#{stanza}", global: false))
    assert :ok = WorkflowStore.force_reload()
  end

  defp setup_fake_turn!(suffix, observers) do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-oxe13a-#{suffix}-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "OXE-#{String.upcase(suffix)}")
    codex_binary = Path.join(test_root, "fake-codex")
    File.mkdir_p!(workspace)
    File.write!(codex_binary, fake_codex_script())
    File.chmod!(codex_binary, 0o755)
    on_exit(fn -> File.rm_rf(test_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    configure_extensions!(observers)

    %{
      workspace: workspace,
      issue: observer_issue("turn-#{suffix}", "OXE-#{String.upcase(suffix)}")
    }
  end

  defp fake_codex_script do
    """
    #!/bin/sh
    count=0
    while IFS= read -r _line; do
      count=$((count + 1))
      case "$count" in
        1) printf '%s\n' '{"id":1,"result":{}}' ;;
        2) ;;
        3) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-observer"}}}' ;;
        4)
          printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-observer"}}}'
          printf '%s\n' '{"method":"item/updated","usage":{"input_tokens":7,"cached_input_tokens":2,"output_tokens":3,"total_tokens":10}}'
          printf '%s\n' '{"method":"turn/completed"}'
          exit 0
          ;;
        *) exit 0 ;;
      esac
    done
    """
  end

  defp observer_issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "private observer title #{identifier} do-not-log",
      description: "private observer description #{id} do-not-log",
      state: "In Progress",
      url: "https://example.invalid/#{identifier}",
      labels: [],
      dispatchable: true
    }
  end

  defp receive_observer_envelopes(count) do
    for _index <- 1..count do
      assert_receive {:oxe13a_observer, envelope}, 1_000
      envelope
    end
  end

  defp drain_subscriber_messages(acc \\ []) do
    receive do
      {:oxe13a_subscriber_capture, message} -> drain_subscriber_messages([message | acc])
      {:oxe13a_subscriber, message} -> drain_subscriber_messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
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

  defp event_id(issue_id, thread_id, turn_id, sequence, event_type) do
    receipt =
      Jason.encode!([
        1,
        "codex_app_server",
        issue_id,
        thread_id,
        turn_id,
        sequence,
        event_type
      ])

    "evt_" <> sha256(receipt)
  end

  defp sha256(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end

  defp fixed_log_body(log) do
    log
    |> String.split("\n", trim: true)
    |> List.last()
    |> String.split("[error] ", parts: 2)
    |> List.last()
  end

  defp delivery_failure_log_bodies(log), do: log_bodies(log, "telemetry.delivery_failed")
  defp observer_failure_log_bodies(log), do: log_bodies(log, "telemetry.observer_failed")

  defp log_bodies(log, marker) do
    log
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.contains?(&1, marker))
    |> Enum.map(fn line ->
      line
      |> String.split("[error] ", parts: 2)
      |> List.last()
    end)
  end

  defp observer_failure_line(event_id, adapter, registry_revision, class) do
    "telemetry.observer_failed event_id=#{event_id} interface=delivery_observer " <>
      "adapter=#{inspect(adapter)} registry_revision=#{registry_revision} class=#{class}"
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

  defp drain_dispatcher!(timeout_ms), do: call(:drain_observers, [timeout_ms])

  defp drain_dispatcher_if_available(timeout_ms) do
    if function_exported?(Extensions, :drain_observers, 1) do
      _result = drain_dispatcher!(timeout_ms)
    end

    :ok
  end

  defp reset_registry! do
    if function_exported?(ExtensionRegistry, :reset_for_test, 0) do
      ExtensionRegistry.reset_for_test()
    else
      :ok
    end
  end

  defp call(function, arguments), do: apply(Extensions, function, arguments)
end
