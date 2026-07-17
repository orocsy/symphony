defmodule SymphonyElixir.ValidationController do
  @moduledoc """
  Validates one MIU commit-range checkpoint and issues runtime-owned evidence.
  """

  alias SymphonyElixir.{ControllerEvidence, DispatchPreflight, Linear.Issue, RuntimeContract, RuntimeRequest, Workspace}

  @authority "symphony.runtime.validation-controller"
  @attempts_path ".orocsy/delivery/state/validation-attempts.jsonl"
  @events_path ".orocsy/delivery/events/events.jsonl"
  @certificates_dir ".orocsy/delivery/state/miu-certificates"
  @validation_logs_dir ".orocsy/delivery/validation"
  @max_log_bytes 20_000
  @max_capture_bytes 1_000_000
  @infrastructure_failure_classes ~w(command_launch_failed command_timed_out)
  @product_failure_classes ~w(command_failed test_count_unavailable zero_tests_collected tests_failed)

  @spec process_requests(Issue.t(), String.t()) ::
          :none | {:ok, map()} | {:error, term()} | {:blocked, term()}
  def process_requests(%Issue{} = issue, workspace) when is_binary(workspace) do
    case structured_contract(issue) do
      {:ok, compiled} ->
        contract_identity = %{
          "contract_hash" => compiled.contract_hash,
          "issue_revision" => RuntimeContract.issue_revision(issue.description, issue.updated_at)
        }

        process_miu_request(issue, workspace, contract_identity)

      {:error, reason} = error ->
        process_invalid_contract_request(workspace, "miu.completion_requested", reason, error)
    end
  end

  def process_requests(_issue, _workspace), do: :none

  defp process_miu_request(issue, workspace, contract_identity) do
    case RuntimeRequest.latest_unprocessed(workspace, "miu.completion_requested", contract_identity) do
      {:ok, request} ->
        miu_id = request["miu_id"] || request["step"]

        process_named_miu_request(issue, workspace, request, miu_id)

      {:stale, request, reason} ->
        :ok = RuntimeRequest.mark_processed(workspace, request, "stale", %{"reason" => inspect(reason)})
        :none

      :none ->
        :none
    end
  end

  defp process_named_miu_request(issue, workspace, request, miu_id)
       when is_binary(miu_id) and miu_id != "" do
    result =
      case current_certificate(workspace, issue, miu_id) do
        {:ok, certificate} -> {:ok, certificate}
        :none -> certify_miu(issue, workspace, miu_id)
      end

    case reconcile_runtime_corrections(issue, workspace, miu_id, result) do
      :ok ->
        :ok = record_request_result(workspace, request, result)
        result

      {:error, reason} ->
        {:error, {:runtime_correction_reconciliation_failed, reason, result}}
    end
  end

  defp process_named_miu_request(_issue, workspace, request, _miu_id) do
    result = {:error, :missing_miu_request_step}
    :ok = record_request_result(workspace, request, result)
    result
  end

  defp process_invalid_contract_request(workspace, event_type, reason, result) do
    case RuntimeRequest.latest_unprocessed(workspace, event_type) do
      {:ok, request} ->
        :ok = RuntimeRequest.mark_processed(workspace, request, "failed", %{"reason" => inspect(reason)})
        result

      {:stale, request, stale_reason} ->
        :ok = RuntimeRequest.mark_processed(workspace, request, "stale", %{"reason" => inspect(stale_reason)})
        :none

      :none ->
        :none
    end
  end

  @spec certify_miu(Issue.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()} | {:blocked, term()}
  def certify_miu(%Issue{} = issue, workspace, miu_id)
      when is_binary(workspace) and is_binary(miu_id) do
    with {:ok, compiled} <- structured_contract(issue),
         {:ok, miu} <- fetch_miu(compiled.contract, miu_id),
         {:ok, branch} <- git(workspace, ["branch", "--show-current"]),
         true <- branch == compiled.contract["integration_branch"] || {:error, :canonical_branch_mismatch},
         true <- clean_worktree?(workspace) || {:error, :dirty_worktree},
         {:ok, head_sha} <- git(workspace, ["rev-parse", "HEAD"]),
         :ok <- ensure_next_miu(issue, workspace, compiled, head_sha, miu_id),
         {:ok, base_head_sha} <- certification_base_sha(issue, workspace, compiled, head_sha, miu_id),
         {:ok, changed_paths} <- changed_paths(workspace, base_head_sha, head_sha),
         true <- changed_paths != [] || {:error, :empty_miu_commit},
         true <- paths_allowed?(changed_paths, miu["write_scope"]) || {:error, {:undeclared_write, changed_paths}},
         true <-
           not paths_denied?(changed_paths, compiled.denied_scope) ||
             {:error, {:denied_scope_write, changed_paths}},
         {:ok, validation_events} <- run_validations(issue, workspace, compiled, miu, head_sha),
         {:ok, ^head_sha} <- unchanged_head(workspace, head_sha),
         true <- clean_worktree?(workspace) || {:error, :validation_left_dirty_worktree} do
      certificate =
        ControllerEvidence.sign(%{
          "schema_version" => 1,
          "event" => "miu.completed",
          "authority" => @authority,
          "issue_id" => issue.id,
          "issue" => issue.identifier,
          "contract_hash" => compiled.contract_hash,
          "issue_revision" => RuntimeContract.issue_revision(issue.description, issue.updated_at),
          "miu_id" => miu_id,
          "branch" => branch,
          "base_head_sha" => base_head_sha,
          "head_sha" => head_sha,
          "changed_paths" => changed_paths,
          "validation_event_ids" => Enum.map(validation_events, & &1["event_id"]),
          "completed_at" => now()
        })

      :ok = write_certificate(workspace, miu_id, certificate)
      :ok = append_event(workspace, certificate)
      {:ok, certificate}
    else
      false -> {:error, :miu_certification_precondition_failed}
      {:error, _reason} = error -> error
      {:blocked, _reason} = blocked -> blocked
      _ -> {:error, :invalid_miu_certification_request}
    end
  end

  def certify_miu(_issue, _workspace, _miu_id), do: {:error, :invalid_miu_certification_request}

  @spec certificates(String.t()) :: [map()]
  def certificates(workspace) when is_binary(workspace) do
    workspace
    |> Path.join(Path.join(@certificates_dir, "*.json"))
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, certificate} when is_map(certificate) ->
              if ControllerEvidence.valid?(certificate), do: [certificate], else: []

            _ ->
              []
          end

        _ ->
          []
      end
    end)
  end

  def certificates(_workspace), do: []

  @spec certified_miu_ids(Issue.t(), String.t()) :: [String.t()]
  def certified_miu_ids(%Issue{} = issue, workspace) when is_binary(workspace) do
    with {:ok, compiled} <- structured_contract(issue),
         {:ok, head_sha} <- git(workspace, ["rev-parse", "HEAD"]) do
      valid_certified_miu_ids(issue, workspace, compiled, head_sha)
    else
      _ -> []
    end
  end

  def certified_miu_ids(_issue, _workspace), do: []

  @spec validate_final(Issue.t(), String.t()) :: {:ok, [map()]} | {:error, term()} | {:blocked, term()}
  def validate_final(%Issue{} = issue, workspace) when is_binary(workspace) do
    with {:ok, compiled} <- structured_contract(issue),
         {:ok, branch} <- git(workspace, ["branch", "--show-current"]),
         true <- branch == compiled.contract["integration_branch"] || {:error, :canonical_branch_mismatch},
         true <- clean_worktree?(workspace) || {:error, :dirty_worktree},
         {:ok, head_sha} <- git(workspace, ["rev-parse", "HEAD"]),
         {:ok, events} <-
           run_validations(
             issue,
             workspace,
             compiled,
             %{"id" => "__final__", "validations" => compiled.contract["final_validations"]},
             head_sha
           ),
         {:ok, ^head_sha} <- unchanged_head(workspace, head_sha),
         true <- clean_worktree?(workspace) || {:error, :validation_left_dirty_worktree} do
      {:ok, events}
    else
      {:error, _reason} = error -> error
    end
  end

  def validate_final(_issue, _workspace), do: {:error, :invalid_final_validation_request}

  @spec validate_review_rework_delta(Issue.t(), String.t(), String.t()) ::
          {:ok, [map()]} | {:error, term()} | {:blocked, term()}
  def validate_review_rework_delta(%Issue{} = issue, workspace, certified_head_sha)
      when is_binary(workspace) and is_binary(certified_head_sha) do
    with {:ok, compiled} <- structured_contract(issue),
         :ok <- validate_review_rework_preflight(issue, workspace, compiled, certified_head_sha),
         {:ok, branch} <- git(workspace, ["branch", "--show-current"]),
         true <- branch == compiled.contract["integration_branch"] || {:error, :canonical_branch_mismatch},
         true <- clean_worktree?(workspace) || {:error, :dirty_worktree},
         {:ok, head_sha} <- git(workspace, ["rev-parse", "HEAD"]),
         true <- certified_head_sha != head_sha || {:error, :empty_review_rework_delta},
         true <- git_ancestor?(workspace, certified_head_sha, head_sha) || {:error, :review_rework_base_not_ancestor},
         {:ok, changed_paths} <- changed_paths_across_commits(workspace, certified_head_sha, head_sha),
         true <- changed_paths != [] || {:error, :empty_review_rework_delta},
         true <-
           not paths_denied?(changed_paths, compiled.denied_scope) ||
             {:error, {:denied_scope_write, changed_paths}},
         {:ok, validations} <- review_rework_validations(compiled, changed_paths),
         {:ok, events} <-
           run_validations(
             issue,
             workspace,
             compiled,
             %{"id" => "__review_rework__", "validations" => validations},
             head_sha
           ),
         {:ok, ^head_sha} <- unchanged_head(workspace, head_sha),
         true <- clean_worktree?(workspace) || {:error, :validation_left_dirty_worktree} do
      {:ok, events}
    else
      false -> {:error, :review_rework_validation_precondition_failed}
      {:error, _reason} = error -> error
      {:blocked, _reason} = blocked -> blocked
      _ -> {:error, :invalid_review_rework_validation_request}
    end
  end

  def validate_review_rework_delta(_issue, _workspace, _certified_head_sha),
    do: {:error, :invalid_review_rework_validation_request}

  defp structured_contract(%Issue{} = issue) do
    case RuntimeContract.compile(issue.description) do
      {:ok, compiled} -> {:ok, compiled}
      :none -> {:error, :legacy_or_missing_runtime_contract}
      {:error, errors} -> {:error, {:invalid_runtime_contract, errors}}
    end
  end

  defp fetch_miu(contract, miu_id) do
    case Enum.find(contract["mius"], &(&1["id"] == miu_id)) do
      nil -> {:error, {:unknown_miu, miu_id}}
      miu -> {:ok, miu}
    end
  end

  defp ensure_next_miu(issue, workspace, compiled, head_sha, requested_miu_id) do
    completed_ids = valid_certified_miu_ids(issue, workspace, compiled, head_sha) |> MapSet.new()

    case Enum.find(compiled.miu_ids, &(not MapSet.member?(completed_ids, &1))) do
      ^requested_miu_id -> :ok
      nil -> {:error, :all_mius_already_certified}
      next_miu_id -> {:error, {:miu_out_of_order, requested_miu_id, next_miu_id}}
    end
  end

  defp valid_certified_miu_ids(issue, workspace, compiled, head_sha) do
    issue
    |> valid_miu_certificates(workspace, compiled, head_sha)
    |> Enum.map(& &1["miu_id"])
    |> Enum.uniq()
  end

  defp valid_miu_certificates(issue, workspace, compiled, head_sha) do
    expected_revision = RuntimeContract.issue_revision(issue.description, issue.updated_at)

    workspace
    |> certificates()
    |> Enum.filter(fn certificate ->
      certificate["event"] == "miu.completed" and
        certificate["authority"] == @authority and
        certificate["issue_id"] == issue.id and
        certificate["issue"] == issue.identifier and
        certificate["contract_hash"] == compiled.contract_hash and
        certificate["issue_revision"] == expected_revision and
        certificate["branch"] == compiled.contract["integration_branch"] and
        valid_certificate_range?(workspace, certificate) and
        git_ancestor?(workspace, certificate["head_sha"], head_sha)
    end)
    |> Enum.filter(&(&1["miu_id"] in compiled.miu_ids))
  end

  defp certification_base_sha(issue, workspace, compiled, head_sha, miu_id) do
    miu_index = Enum.find_index(compiled.miu_ids, &(&1 == miu_id))

    case miu_index do
      0 ->
        initial_certification_base_sha(issue, workspace, compiled, head_sha)

      index when is_integer(index) and index > 0 ->
        previous_miu_id = Enum.at(compiled.miu_ids, index - 1)

        issue
        |> valid_miu_certificates(workspace, compiled, head_sha)
        |> Enum.find(&(&1["miu_id"] == previous_miu_id))
        |> case do
          %{"head_sha" => previous_head_sha} when is_binary(previous_head_sha) -> {:ok, previous_head_sha}
          _ -> {:error, {:missing_prior_miu_certificate, previous_miu_id}}
        end

      _ ->
        {:error, {:unknown_miu, miu_id}}
    end
  end

  defp initial_certification_base_sha(issue, workspace, compiled, head_sha) do
    case dispatch_certification_base_sha(issue, workspace, compiled, head_sha) do
      {:ok, base_sha} ->
        {:ok, base_sha}

      :none ->
        integration_certification_base_sha(workspace, compiled, head_sha)

      {:error, _reason} = error ->
        error
    end
  end

  defp integration_certification_base_sha(workspace, compiled, head_sha) do
    integration_ref = "refs/remotes/origin/#{compiled.contract["integration_branch"]}"

    case git(workspace, ["rev-parse", "--verify", integration_ref]) do
      {:ok, integration_sha} ->
        if git_ancestor?(workspace, integration_sha, head_sha) do
          {:ok, integration_sha}
        else
          base_branch_merge_base(workspace, compiled.contract["base_branch"], head_sha)
        end

      {:error, _reason} ->
        base_branch_merge_base(workspace, compiled.contract["base_branch"], head_sha)
    end
  end

  defp dispatch_certification_base_sha(issue, workspace, compiled, head_sha) do
    case DispatchPreflight.read_authoritative(workspace) do
      {:ok, preflight} ->
        validate_dispatch_certification_base(issue, workspace, compiled, head_sha, preflight)

      :none ->
        :none

      {:error, reason} ->
        {:error, {:invalid_dispatch_preflight, reason}}
    end
  end

  defp validate_dispatch_certification_base(issue, workspace, compiled, head_sha, preflight) do
    expected_revision = RuntimeContract.issue_revision(issue.description, issue.updated_at)

    cond do
      preflight["issue_id"] != issue.id ->
        {:error, :dispatch_preflight_issue_id_mismatch}

      preflight["issue"] != issue.identifier ->
        {:error, :dispatch_preflight_issue_mismatch}

      preflight["branch"] != compiled.contract["integration_branch"] ->
        {:error, :dispatch_preflight_branch_mismatch}

      preflight["contract_hash"] != compiled.contract_hash ->
        {:error, :dispatch_preflight_contract_mismatch}

      preflight["issue_revision"] != expected_revision ->
        {:error, :dispatch_preflight_issue_revision_mismatch}

      is_nil(preflight["certification_base_sha"]) ->
        :none

      not is_binary(preflight["certification_base_sha"]) or
          preflight["certification_base_sha"] == "" ->
        {:error, :invalid_dispatch_certification_base}

      not git_ancestor?(workspace, preflight["certification_base_sha"], head_sha) ->
        {:error, {:dispatch_certification_base_not_ancestor, preflight["certification_base_sha"], head_sha}}

      true ->
        {:ok, preflight["certification_base_sha"]}
    end
  end

  defp base_branch_merge_base(workspace, base_branch, head_sha) do
    ["refs/remotes/origin/#{base_branch}", "refs/heads/#{base_branch}"]
    |> Enum.reduce_while({:error, {:base_branch_unavailable, base_branch}}, fn ref, _error ->
      case git(workspace, ["merge-base", ref, head_sha]) do
        {:ok, base_sha} -> {:halt, {:ok, base_sha}}
        {:error, _reason} = error -> {:cont, error}
      end
    end)
  end

  defp changed_paths(workspace, base_head_sha, head_sha) do
    case git(workspace, ["diff", "--name-only", "--no-renames", "#{base_head_sha}..#{head_sha}", "--"]) do
      {:ok, output} -> {:ok, String.split(output, "\n", trim: true)}
      error -> error
    end
  end

  defp changed_paths_across_commits(workspace, base_head_sha, head_sha) do
    case git(workspace, [
           "log",
           "--format=",
           "--name-only",
           "--no-renames",
           "-m",
           "#{base_head_sha}..#{head_sha}",
           "--"
         ]) do
      {:ok, output} ->
        paths = output |> String.split("\n", trim: true) |> Enum.uniq() |> Enum.sort()
        {:ok, paths}

      error ->
        error
    end
  end

  defp paths_allowed?(changed_paths, allowed_scope) do
    Enum.all?(changed_paths, fn path ->
      Enum.any?(allowed_scope, &path_matches_scope?(path, &1))
    end)
  end

  defp paths_denied?(changed_paths, denied_scope) do
    Enum.any?(changed_paths, fn path ->
      Enum.any?(denied_scope, &path_matches_scope?(path, &1))
    end)
  end

  defp path_matches_scope?(path, scope) when is_binary(path) and is_binary(scope) do
    path == scope or Regex.match?(glob_regex(scope), path)
  end

  defp path_matches_scope?(_path, _scope), do: false

  defp review_rework_validations(compiled, changed_paths) do
    mius = compiled.contract["mius"]
    allowed_scope = Enum.flat_map(mius, & &1["write_scope"])

    if paths_allowed?(changed_paths, allowed_scope) do
      affected_validations =
        mius
        |> Enum.filter(fn miu ->
          Enum.any?(changed_paths, fn path ->
            Enum.any?(miu["write_scope"], &path_matches_scope?(path, &1))
          end)
        end)
        |> Enum.flat_map(& &1["validations"])

      {:ok, Enum.uniq(affected_validations ++ compiled.contract["final_validations"])}
    else
      undeclared_paths =
        Enum.reject(changed_paths, fn path ->
          Enum.any?(allowed_scope, &path_matches_scope?(path, &1))
        end)

      {:error, {:undeclared_review_rework_write, undeclared_paths}}
    end
  end

  defp validate_review_rework_preflight(issue, workspace, compiled, certified_head_sha) do
    expected_revision = RuntimeContract.issue_revision(issue.description, issue.updated_at)

    case DispatchPreflight.read_authoritative(workspace) do
      {:ok, preflight} ->
        cond do
          preflight["mode"] != "review_rework" ->
            {:error, :review_rework_dispatch_preflight_required}

          preflight["issue_id"] != issue.id or preflight["issue"] != issue.identifier ->
            {:error, :review_rework_dispatch_issue_mismatch}

          preflight["branch"] != compiled.contract["integration_branch"] ->
            {:error, :review_rework_dispatch_branch_mismatch}

          preflight["contract_hash"] != compiled.contract_hash ->
            {:error, :review_rework_dispatch_contract_mismatch}

          preflight["issue_revision"] != expected_revision ->
            {:error, :review_rework_dispatch_issue_revision_mismatch}

          (preflight["review_delta_base_head"] || get_in(preflight, ["review", "head_sha"])) !=
              certified_head_sha ->
            {:error, :review_rework_dispatch_base_mismatch}

          true ->
            :ok
        end

      :none ->
        {:error, :review_rework_dispatch_preflight_required}

      {:error, reason} ->
        {:error, {:invalid_review_rework_dispatch_preflight, reason}}
    end
  end

  defp glob_regex(scope) do
    scope
    |> Regex.escape()
    |> String.replace("\\*\\*", ".*")
    |> String.replace("\\*", "[^/]*")
    |> then(&Regex.compile!("^" <> &1 <> "$"))
  end

  defp run_validations(issue, workspace, compiled, miu, head_sha) do
    Enum.reduce_while(miu["validations"], {:ok, []}, fn command, {:ok, events} ->
      fingerprint = validation_fingerprint(issue, workspace, compiled, miu["id"], head_sha, command)
      prior_product_failures = product_failure_count(workspace, issue, compiled, miu["id"], command)
      prior_infrastructure_failures = infrastructure_failure_count(workspace, issue, compiled, miu["id"], command)

      cond do
        failed_attempt = failed_fingerprint(workspace, fingerprint) ->
          reason =
            if infrastructure_failure?(failed_attempt) do
              {:unchanged_infrastructure_validation, fingerprint}
            else
              {:unchanged_failed_validation, fingerprint}
            end

          {:halt, {:blocked, reason}}

        infrastructure_failure_in_current_environment?(workspace, issue, compiled, miu["id"], command) ->
          {:halt, {:blocked, {:unchanged_infrastructure_environment, miu["id"]}}}

        prior_infrastructure_failures >= 2 ->
          {:halt, {:blocked, {:infrastructure_retry_budget_exhausted, miu["id"]}}}

        true ->
          result = execute_validation(issue, workspace, compiled, miu["id"], head_sha, command, fingerprint)
          :ok = append_attempt(workspace, result)
          :ok = append_event(workspace, result)

          case validation_state_unchanged(workspace, head_sha) do
            :ok ->
              continue_after_validation(result, events, prior_product_failures, miu["id"])

            {:error, _reason} = error ->
              {:halt, error}
          end
      end
    end)
  end

  defp continue_after_validation(%{"status" => "passed"} = result, events, _prior_failures, _miu_id),
    do: {:cont, {:ok, events ++ [result]}}

  defp continue_after_validation(result, _events, prior_product_failures, miu_id) do
    if product_failure?(result) and prior_product_failures >= 2 do
      {:halt, {:blocked, {:product_fix_budget_exhausted, miu_id}}}
    else
      {:halt, {:error, {:validation_failed, result}}}
    end
  end

  defp execute_validation(issue, workspace, compiled, miu_id, head_sha, command, fingerprint) do
    started = System.monotonic_time(:millisecond)
    timeout_ms = compiled.contract["validation_timeout_ms"]
    {output, exit_code, timed_out?, launch_failed?} = run_command(workspace, command, timeout_ms)
    duration_ms = max(0, System.monotonic_time(:millisecond) - started)
    tests = test_counts(command, output)
    {status, reason_class} = validation_status(command, exit_code, tests, timed_out?, launch_failed?)
    event_id = "validation-" <> String.slice(fingerprint, -16, 16)
    bounded_output = truncate(output, @max_log_bytes)
    log_path = write_validation_log(workspace, event_id, bounded_output)

    ControllerEvidence.sign(%{
      "schema_version" => 1,
      "event" => "validation.completed",
      "event_id" => event_id,
      "authority" => @authority,
      "issue" => issue.identifier,
      "contract_hash" => compiled.contract_hash,
      "miu_id" => miu_id,
      "head_sha" => head_sha,
      "command" => command,
      "command_hash" => "sha256:" <> sha256(command),
      "environment_fingerprint" => environment_fingerprint(workspace),
      "validation_fingerprint" => fingerprint,
      "status" => status,
      "reason_class" => reason_class,
      "exit_code" => exit_code,
      "timeout_ms" => timeout_ms,
      "timed_out" => timed_out?,
      "tests" => tests,
      "duration_ms" => duration_ms,
      "output_digest" => "sha256:" <> sha256(output),
      "bounded_log_path" => log_path,
      "ts" => now()
    })
  end

  defp run_command(workspace, command, timeout_ms) do
    case OptionParser.split(command) do
      parts when parts != [] ->
        {env, [executable | args]} = split_env_assignments(parts)
        executable = resolve_executable(executable, workspace)
        port = open_command_port(executable, args, workspace, env)

        {output, exit_code, timed_out?} =
          collect_command(port, timeout_ms, System.monotonic_time(:millisecond), "")

        {output, exit_code, timed_out?, false}

      [] ->
        {"empty validation command", 127, false, true}
    end
  rescue
    error -> {Exception.message(error), 127, false, true}
  end

  defp split_env_assignments(parts) do
    Enum.split_while(parts, &env_assignment?/1)
  end

  defp env_assignment?(part) when is_binary(part), do: Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=.*/, part)
  defp env_assignment?(_part), do: false

  defp validation_status(_command, _exit_code, _tests, _timed_out?, true),
    do: {"failed", "command_launch_failed"}

  defp validation_status(_command, _exit_code, _tests, true, false), do: {"failed", "command_timed_out"}

  defp validation_status(_command, exit_code, _tests, false, false) when exit_code != 0,
    do: {"failed", "command_failed"}

  defp validation_status(command, 0, tests, false, false) do
    cond do
      not test_command?(command) -> {"passed", "passed"}
      tests == nil -> {"failed", "test_count_unavailable"}
      tests["collected"] == 0 -> {"failed", "zero_tests_collected"}
      tests["failed"] > 0 -> {"failed", "tests_failed"}
      true -> {"passed", "passed"}
    end
  end

  defp test_counts(command, output) do
    if test_command?(command) do
      output = strip_ansi(output)

      cond do
        match = Regex.run(~r/Ran\s+(\d+)\s+tests?\s+in\s+[\d.]+s/i, output, capture: :all_but_first) ->
          [collected] = Enum.map(match, &String.to_integer/1)
          %{"collected" => collected, "passed" => collected, "failed" => 0}

        match = Regex.run(~r/Tests:\s*(?:(\d+)\s+failed,\s*)?(?:(\d+)\s+passed,\s*)?(\d+)\s+total/i, output, capture: :all_but_first) ->
          [failed, passed, collected] =
            Enum.map(match, fn value -> if value == "", do: 0, else: String.to_integer(value) end)

          %{"collected" => collected, "passed" => passed, "failed" => failed}

        match = Regex.run(~r/(\d+)\s+tests?,\s+(\d+)\s+failures?/i, output, capture: :all_but_first) ->
          [collected, failed] = Enum.map(match, &String.to_integer/1)
          %{"collected" => collected, "passed" => max(0, collected - failed), "failed" => failed}

        match = Regex.run(~r/Tests\s+(?:(\d+)\s+failed\s*\|\s*)?(\d+)\s+passed/i, output, capture: :all_but_first) ->
          [failed, passed] = Enum.map(match, fn value -> if value == "", do: 0, else: String.to_integer(value) end)
          %{"collected" => passed + failed, "passed" => passed, "failed" => failed}

        match = Regex.run(~r/(\d+)\s+passed(?:,\s*(\d+)\s+failed)?\s+in\s+[\d.]+s/i, output, capture: :all_but_first) ->
          [passed, failed] =
            match
            |> then(fn
              [passed] -> [passed, "0"]
              [passed, failed] -> [passed, failed]
            end)
            |> Enum.map(&String.to_integer/1)

          %{"collected" => passed + failed, "passed" => passed, "failed" => failed}

        match = Regex.run(~r/(\d+)\s+passed(?:,\s*(\d+)\s+failed)?\s+\([\d.]+s\)/i, output, capture: :all_but_first) ->
          [passed, failed] =
            match
            |> then(fn
              [passed] -> [passed, "0"]
              [passed, failed] -> [passed, failed]
            end)
            |> Enum.map(&String.to_integer/1)

          %{"collected" => passed + failed, "passed" => passed, "failed" => failed}

        true ->
          nil
      end
    end
  end

  defp strip_ansi(output) when is_binary(output) do
    Regex.replace(~r/\x1B\[[0-?]*[ -\/]*[@-~]/, output, "")
  end

  defp test_command?(command) do
    Regex.match?(~r/(^|[\s\/.\-_])(test|tests|unittest|jest|vitest|pytest)([\s\/.\-_:]|$)/i, command)
  end

  defp validation_fingerprint(issue, workspace, compiled, miu_id, head_sha, command) do
    [
      issue.id,
      issue.identifier,
      compiled.contract_hash,
      miu_id,
      head_sha,
      "sha256:" <> sha256(command),
      environment_fingerprint(workspace)
    ]
    |> Enum.map_join("\n", &to_string/1)
    |> sha256()
    |> then(&("sha256:" <> &1))
  end

  defp environment_fingerprint(workspace) do
    lock_digest =
      ["pnpm-lock.yaml", "mix.lock", "package-lock.json", "yarn.lock"]
      |> Enum.find_value("none", fn name ->
        path = Path.join(workspace, name)
        if File.regular?(path), do: sha256(File.read!(path))
      end)

    [System.version(), System.otp_release(), lock_digest]
    |> Enum.join("\n")
    |> sha256()
    |> then(&("sha256:" <> &1))
  end

  defp failed_fingerprint(workspace, fingerprint) do
    workspace
    |> trusted_attempts()
    |> Enum.find(&(&1["validation_fingerprint"] == fingerprint and &1["status"] == "failed"))
  end

  defp product_failure_count(workspace, issue, compiled, miu_id, command) do
    command_hash = "sha256:" <> sha256(command)

    workspace
    |> trusted_attempts()
    |> Enum.count(fn attempt ->
      product_failure?(attempt) and
        attempt["issue"] == issue.identifier and
        attempt["contract_hash"] == compiled.contract_hash and
        attempt["miu_id"] == miu_id and
        attempt["command_hash"] == command_hash
    end)
  end

  defp product_failure?(%{"status" => "failed", "reason_class" => reason_class}) do
    reason_class in @product_failure_classes
  end

  defp product_failure?(_attempt), do: false

  defp infrastructure_failure_count(workspace, issue, compiled, miu_id, command) do
    command_hash = "sha256:" <> sha256(command)

    workspace
    |> trusted_attempts()
    |> Enum.count(fn attempt ->
      infrastructure_failure?(attempt) and
        attempt["issue"] == issue.identifier and
        attempt["contract_hash"] == compiled.contract_hash and
        attempt["miu_id"] == miu_id and
        attempt["command_hash"] == command_hash
    end)
  end

  defp infrastructure_failure_in_current_environment?(workspace, issue, compiled, miu_id, command) do
    command_hash = "sha256:" <> sha256(command)
    current_environment = environment_fingerprint(workspace)

    workspace
    |> trusted_attempts()
    |> Enum.any?(fn attempt ->
      infrastructure_failure?(attempt) and
        attempt["issue"] == issue.identifier and
        attempt["contract_hash"] == compiled.contract_hash and
        attempt["miu_id"] == miu_id and
        attempt["command_hash"] == command_hash and
        attempt["environment_fingerprint"] == current_environment
    end)
  end

  defp infrastructure_failure?(%{"status" => "failed", "reason_class" => reason_class}),
    do: reason_class in @infrastructure_failure_classes

  defp infrastructure_failure?(_attempt), do: false

  defp record_request_result(workspace, request, result) do
    {status, attributes} =
      case result do
        {:ok, certificate} -> {"completed", %{"certificate_head_sha" => certificate["head_sha"]}}
        {:blocked, reason} -> {"blocked", %{"reason" => inspect(reason)}}
        {:error, reason} -> {"failed", %{"reason" => inspect(reason)}}
      end

    RuntimeRequest.mark_processed(workspace, request, status, attributes)
  end

  @spec reconcile_runtime_corrections(Issue.t(), String.t(), String.t(), term()) :: :ok | {:error, term()}
  def reconcile_runtime_corrections(_issue, workspace, miu_id, {:ok, certificate}) do
    correction_ids =
      workspace
      |> Workspace.open_blocking_corrections_in_workspace()
      |> Enum.filter(&validation_correction_for_miu?(&1, miu_id))
      |> Enum.map(& &1["correction_id"])
      |> Enum.filter(&is_binary/1)

    if correction_ids == [] do
      :ok
    else
      Workspace.resolve_blocking_corrections_by_id_in_workspace(
        workspace,
        correction_ids,
        "Runtime controller validation passed for #{miu_id} at #{certificate["head_sha"]}; the matching validation correction is resolved."
      )
    end
  end

  def reconcile_runtime_corrections(
        issue,
        workspace,
        miu_id,
        {:error, {:validation_failed, event}} = result
      )
      when is_map(event) do
    head_sha = git_value(workspace, ["rev-parse", "HEAD"])

    if existing_controller_validation_correction?(workspace, miu_id, head_sha) do
      :ok
    else
      attrs = validation_correction_attrs(issue, workspace, miu_id, head_sha, result)

      case Workspace.create_correction_in_workspace(workspace, issue, attrs) do
        {:ok, _correction} -> :ok
        {:error, reason} -> {:error, {:validation_correction_write_failed, reason}}
      end
    end
  end

  def reconcile_runtime_corrections(issue, workspace, miu_id, {:blocked, reason}) do
    head_sha = git_value(workspace, ["rev-parse", "HEAD"])

    with :ok <- resolve_retryable_validation_corrections(workspace, miu_id, reason),
         false <- existing_controller_block_correction?(workspace, miu_id, head_sha),
         {:ok, _correction} <-
           Workspace.create_correction_in_workspace(
             workspace,
             issue,
             validation_block_correction_attrs(issue, miu_id, head_sha, reason)
           ) do
      :ok
    else
      true -> :ok
      {:error, correction_reason} -> {:error, {:validation_block_correction_write_failed, correction_reason}}
    end
  end

  def reconcile_runtime_corrections(_issue, _workspace, _miu_id, _result), do: :ok

  defp validation_correction_attrs(_issue, workspace, "__final__", head_sha, {:error, {:validation_failed, event}})
       when is_map(event) do
    %{
      source: @authority,
      source_status: "blocked",
      summary: "Final authoritative validation failed",
      findings:
        [
          "Command: #{event["command"]}",
          "Reason: #{event["reason_class"]}; exit code: #{event["exit_code"]}",
          validation_output_finding(workspace, event)
        ]
        |> Enum.reject(&is_nil/1),
      required_corrections: [
        "Do not create a post-certification commit. An operator must either repair the validation environment and request final handoff again at the same head, or add an explicit repair MIU to the Runtime Contract before any code change."
      ],
      next_action: "block",
      guard: %{
        "miu_id" => "__final__",
        "head_sha" => head_sha,
        "validation_event_id" => event["event_id"],
        "bounded_log_path" => event["bounded_log_path"]
      }
    }
  end

  defp validation_correction_attrs(issue, workspace, "__review_rework__", head_sha, {:error, {:validation_failed, event}})
       when is_map(event) do
    %{
      source: @authority,
      source_status: "failed",
      summary: "Review-rework authoritative validation failed",
      findings:
        [
          "Command: #{event["command"]}",
          "Reason: #{event["reason_class"]}; exit code: #{event["exit_code"]}",
          correction_scope_finding(issue, "__review_rework__"),
          validation_output_finding(workspace, event)
        ]
        |> Enum.reject(&is_nil/1),
      required_corrections: [
        "Use the supplied command output to make the smallest scoped review fix, create and push a new review-rework commit, append handoff.requested, and stop. Do not rerun the controller-owned validation inside the Codex worker."
      ],
      next_action: "retry",
      guard: %{
        "miu_id" => "__review_rework__",
        "head_sha" => head_sha,
        "validation_event_id" => event["event_id"],
        "bounded_log_path" => event["bounded_log_path"]
      }
    }
  end

  defp validation_correction_attrs(issue, workspace, miu_id, head_sha, {:error, {:validation_failed, event}})
       when is_map(event) do
    %{
      source: @authority,
      source_status: "failed",
      summary: "#{miu_id} authoritative validation failed",
      findings:
        [
          "Command: #{event["command"]}",
          "Reason: #{event["reason_class"]}; exit code: #{event["exit_code"]}",
          correction_scope_finding(issue, miu_id),
          validation_output_finding(workspace, event)
        ]
        |> Enum.reject(&is_nil/1),
      required_corrections: [
        "Use the supplied command output to make the smallest in-scope fix, create a new micro commit, and request #{miu_id} certification again. Do not rerun the controller-owned validation inside the Codex worker."
      ],
      next_action: "retry",
      guard: %{
        "miu_id" => miu_id,
        "head_sha" => head_sha,
        "validation_event_id" => event["event_id"],
        "bounded_log_path" => event["bounded_log_path"]
      }
    }
  end

  defp validation_correction_attrs(issue, _workspace, miu_id, head_sha, result) do
    %{
      source: @authority,
      source_status: "blocked",
      summary: "#{miu_id} runtime certification did not complete",
      findings:
        ["Controller result: #{inspect(result)}", correction_scope_finding(issue, miu_id)]
        |> Enum.reject(&is_nil/1),
      required_corrections: [
        "Resolve the exact controller result within the declared MIU scope, create a new micro commit when code changes are required, and request certification again."
      ],
      next_action: "retry",
      guard: %{"miu_id" => miu_id, "head_sha" => head_sha}
    }
  end

  defp validation_block_correction_attrs(issue, miu_id, head_sha, reason) do
    %{
      source: @authority,
      source_status: "blocked",
      summary: "#{miu_id} authoritative validation retry budget exhausted",
      findings:
        ["Controller block: #{inspect(reason)}", correction_scope_finding(issue, miu_id)]
        |> Enum.reject(&is_nil/1),
      required_corrections: [
        "Do not retry this validation automatically. An operator must correct the environment or revise the Runtime Contract before requesting certification again."
      ],
      next_action: "block",
      guard: %{
        "miu_id" => miu_id,
        "head_sha" => head_sha,
        "reason_class" => blocked_reason_class(reason)
      }
    }
  end

  defp resolve_retryable_validation_corrections(workspace, miu_id, reason) do
    correction_ids =
      workspace
      |> Workspace.open_blocking_corrections_in_workspace()
      |> Enum.filter(fn correction ->
        correction["next_action"] == "retry" and validation_correction_for_miu?(correction, miu_id)
      end)
      |> Enum.map(& &1["correction_id"])
      |> Enum.filter(&is_binary/1)

    if correction_ids == [] do
      :ok
    else
      Workspace.resolve_blocking_corrections_by_id_in_workspace(
        workspace,
        correction_ids,
        "Runtime controller stopped automatic retries for #{miu_id}: #{inspect(reason)}."
      )
    end
  end

  defp existing_controller_block_correction?(workspace, miu_id, head_sha) do
    workspace
    |> Workspace.open_blocking_corrections_in_workspace()
    |> Enum.any?(fn correction ->
      correction["source"] == @authority and correction["next_action"] == "block" and
        get_in(correction, ["guard", "miu_id"]) == miu_id and
        get_in(correction, ["guard", "head_sha"]) == head_sha
    end)
  end

  defp correction_scope_finding(%Issue{} = issue, miu_id) do
    with {:ok, compiled} <- RuntimeContract.compile(issue.description),
         paths when is_list(paths) and paths != [] <- correction_scope_paths(compiled, miu_id) do
      "Declared write scope: #{Enum.join(paths, ", ")}"
    else
      _ -> nil
    end
  end

  defp correction_scope_finding(_issue, _miu_id), do: nil

  defp correction_scope_paths(compiled, "__review_rework__"), do: compiled.write_scope

  defp correction_scope_paths(compiled, miu_id) do
    compiled.contract
    |> Map.get("mius", [])
    |> Enum.find_value([], fn miu -> if miu["id"] == miu_id, do: miu["write_scope"] || [] end)
  end

  defp blocked_reason_class({reason_class, _detail}) when is_atom(reason_class), do: Atom.to_string(reason_class)
  defp blocked_reason_class(reason_class) when is_atom(reason_class), do: Atom.to_string(reason_class)
  defp blocked_reason_class(_reason), do: "validation_blocked"

  defp validation_output_finding(workspace, %{"bounded_log_path" => relative_path})
       when is_binary(relative_path) do
    case workspace |> Path.join(relative_path) |> File.read() do
      {:ok, output} -> "Validation output:\n#{truncate(output, 4_000)}"
      _ -> "Validation log: #{relative_path}"
    end
  end

  defp validation_output_finding(_workspace, _event), do: nil

  defp existing_controller_validation_correction?(workspace, miu_id, head_sha) do
    workspace
    |> Workspace.open_blocking_corrections_in_workspace()
    |> Enum.any?(fn correction ->
      correction["source"] == @authority and
        get_in(correction, ["guard", "miu_id"]) == miu_id and
        get_in(correction, ["guard", "head_sha"]) == head_sha
    end)
  end

  defp validation_correction_for_miu?(correction, miu_id) when is_map(correction) do
    guard_miu_id = get_in(correction, ["guard", "miu_id"])
    source = correction["source"] || ""

    text =
      [
        correction["source"],
        correction["summary"],
        correction["findings"],
        correction["required_corrections"]
      ]
      |> List.flatten()
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")
      |> String.downcase()

    (source == @authority and guard_miu_id == miu_id) or
      (source == "worker-validation" and
         (guard_miu_id == miu_id or
            (String.contains?(text, String.downcase(miu_id)) and
               String.contains?(text, ["validation", "playwright", "vitest", "test"]))))
  end

  defp validation_correction_for_miu?(_correction, _miu_id), do: false

  defp git_value(workspace, args) do
    case git(workspace, args) do
      {:ok, value} -> value
      _ -> "unknown"
    end
  end

  defp resolve_executable(executable, workspace) do
    cond do
      String.starts_with?(executable, "./") -> Path.expand(executable, workspace)
      path = System.find_executable(executable) -> path
      true -> raise "validation executable not found: #{executable}"
    end
  end

  defp open_command_port(executable, args, workspace, env) do
    port_opts =
      [:binary, :exit_status, :stderr_to_stdout, {:args, args}, {:cd, String.to_charlist(workspace)}]
      |> maybe_put_env(env)

    Port.open(
      {:spawn_executable, executable},
      port_opts
    )
  end

  defp maybe_put_env(port_opts, []), do: port_opts

  defp maybe_put_env(port_opts, env) do
    env =
      Enum.map(env, fn assignment ->
        [key, value] = String.split(assignment, "=", parts: 2)
        {String.to_charlist(key), String.to_charlist(value)}
      end)

    port_opts ++ [{:env, env}]
  end

  defp collect_command(port, timeout_ms, started_ms, output) do
    remaining_ms = max(0, timeout_ms - (System.monotonic_time(:millisecond) - started_ms))

    receive do
      {^port, {:data, data}} ->
        collect_command(port, timeout_ms, started_ms, bounded_capture(output <> data))

      {^port, {:exit_status, exit_code}} ->
        {output, exit_code, false}
    after
      remaining_ms ->
        Port.close(port)
        {output <> "\n[validation timed out after #{timeout_ms}ms]\n", 124, true}
    end
  end

  defp bounded_capture(output) when byte_size(output) <= @max_capture_bytes, do: output

  defp bounded_capture(output) do
    keep = @max_capture_bytes - byte_size("...[earlier output truncated]...\n")
    "...[earlier output truncated]...\n" <> binary_part(output, byte_size(output) - keep, keep)
  end

  defp current_certificate(workspace, issue, miu_id) do
    with certificate when is_map(certificate) <-
           Enum.find(certificates(workspace), &(&1["miu_id"] == miu_id)),
         {:ok, compiled} <- structured_contract(issue),
         {:ok, head_sha} <- git(workspace, ["rev-parse", "HEAD"]),
         true <- certificate["event"] == "miu.completed",
         true <- certificate["authority"] == @authority,
         true <- certificate["issue_id"] == issue.id,
         true <- certificate["issue"] == issue.identifier,
         true <- certificate["contract_hash"] == compiled.contract_hash,
         true <- certificate["issue_revision"] == RuntimeContract.issue_revision(issue.description, issue.updated_at),
         true <- certificate["branch"] == compiled.contract["integration_branch"],
         true <- valid_certificate_range?(workspace, certificate),
         true <- certificate["head_sha"] == head_sha do
      {:ok, certificate}
    else
      _ -> :none
    end
  end

  defp decoded_lines(path) do
    if File.regular?(path) do
      path
      |> File.stream!()
      |> Enum.flat_map(fn line ->
        case Jason.decode(String.trim(line)) do
          {:ok, value} when is_map(value) -> [value]
          _ -> []
        end
      end)
    else
      []
    end
  end

  defp trusted_attempts(workspace) do
    workspace
    |> Path.join(@attempts_path)
    |> decoded_lines()
    |> Enum.filter(fn attempt ->
      attempt["event"] == "validation.completed" and
        attempt["authority"] == @authority and
        ControllerEvidence.valid?(attempt)
    end)
  end

  defp unchanged_head(workspace, expected_head_sha) do
    case git(workspace, ["rev-parse", "HEAD"]) do
      {:ok, ^expected_head_sha} = current -> current
      {:ok, current_head_sha} -> {:error, {:validation_changed_head, expected_head_sha, current_head_sha}}
      {:error, _reason} = error -> error
    end
  end

  defp validation_state_unchanged(workspace, expected_head_sha) do
    with {:ok, ^expected_head_sha} <- unchanged_head(workspace, expected_head_sha),
         true <- clean_worktree?(workspace) || {:error, :validation_left_dirty_worktree} do
      :ok
    end
  end

  defp append_attempt(workspace, event), do: append_jsonl(workspace, @attempts_path, event)
  defp append_event(workspace, event), do: append_jsonl(workspace, @events_path, event)

  defp append_jsonl(workspace, relative_path, event) do
    path = Path.join(workspace, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(event) <> "\n", [:append])
    :ok
  end

  defp write_certificate(workspace, miu_id, certificate) do
    path = Path.join([workspace, @certificates_dir, safe_id(miu_id) <> ".json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(certificate, pretty: true) <> "\n")
    :ok
  end

  defp write_validation_log(workspace, event_id, output) do
    relative = Path.join(@validation_logs_dir, safe_id(event_id) <> ".log")
    path = Path.join(workspace, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, output)
    relative
  end

  defp safe_id(value), do: String.replace(to_string(value), ~r/[^A-Za-z0-9_.-]/, "_")

  defp truncate(value, max_bytes) do
    value = String.replace_invalid(value)

    if byte_size(value) <= max_bytes do
      value
    else
      utf8_prefix(value, max_bytes) <> "\n...[truncated]\n"
    end
  end

  defp utf8_prefix(_value, max_bytes) when max_bytes <= 0, do: ""

  defp utf8_prefix(value, max_bytes) do
    prefix = binary_part(value, 0, max_bytes)
    if String.valid?(prefix), do: prefix, else: utf8_prefix(value, max_bytes - 1)
  end

  defp clean_worktree?(workspace) do
    case git(workspace, ["status", "--porcelain=v1", "--untracked-files=all", "--", ".", ":(exclude).orocsy/"]) do
      {:ok, status} -> String.trim(status) == ""
      _ -> false
    end
  end

  defp valid_certificate_range?(workspace, certificate) when is_map(certificate) do
    base_head_sha = certificate["base_head_sha"]
    head_sha = certificate["head_sha"]
    changed_paths = certificate["changed_paths"]

    is_binary(base_head_sha) and base_head_sha != "" and
      is_binary(head_sha) and head_sha != "" and
      base_head_sha != head_sha and
      is_list(changed_paths) and changed_paths != [] and
      git_ancestor?(workspace, base_head_sha, head_sha)
  end

  defp valid_certificate_range?(_workspace, _certificate), do: false

  defp git_ancestor?(workspace, ancestor, head) when is_binary(ancestor) and is_binary(head) do
    match?({_, 0}, System.cmd("git", ["merge-base", "--is-ancestor", ancestor, head], cd: workspace, stderr_to_stdout: true))
  rescue
    _error -> false
  end

  defp git_ancestor?(_workspace, _ancestor, _head), do: false

  defp git(workspace, args) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:git_failed, args, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:git_exception, Exception.message(error)}}
  end

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
