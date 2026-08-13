defmodule SymphonyElixir.ValidationController do
  @moduledoc """
  Validates one MIU commit-range checkpoint and issues runtime-owned evidence.
  """

  alias SymphonyElixir.{ControllerEvidence, DispatchPreflight, Linear.Issue, RuntimeContract, RuntimeRequest, Workspace}
  alias SymphonyElixir.ScopeAccess.Controller, as: ScopeAccessController

  @authority "symphony.runtime.validation-controller"
  @attempts_path ".orocsy/delivery/state/validation-attempts.jsonl"
  @events_path ".orocsy/delivery/events/events.jsonl"
  @certificates_dir ".orocsy/delivery/state/miu-certificates"
  @durable_certificates_dir "miu-certificates"
  @validation_logs_dir ".orocsy/delivery/validation"
  @max_log_bytes 20_000
  @max_capture_bytes 1_000_000
  @infrastructure_failure_classes ~w(command_launch_failed command_timed_out)
  @product_failure_classes ~w(command_failed test_count_unavailable zero_tests_collected tests_failed)
  @sensitive_env_key ~r/(?:^PGPASSWORD$|(?:^|[_-])(?:api[_-]?key|access[_-]?key(?:[_-]?id)?|auth(?:entication|orization)?|credentials?|password|pwd|private[_-]?key|secrets?|tokens?|pat|jwt|(?:database|db|redis|mongo(?:db)?|postgres(?:ql)?|mysql)[_-]?(?:url|uri)|dsn|connection[_-]?string)(?:$|[_-]))/i
  @generic_key_env_key ~r/(?:^|[_-])(?:[A-Z0-9]+[_-])?KEY(?:$|[_-])/i
  @sensitive_proxy_env_key ~r/^(?:[A-Z][A-Z0-9]*_)*(?:HTTP|HTTPS|ALL)_PROXY$/i
  @validation_env_key ~r/^(?:PATH|PATHEXT|HOME|SHELL|TMPDIR|LANG|LC_.+|XDG_.+|CI|(?:HTTP|HTTPS|ALL|NO)_PROXY|SSL_CERT_(?:FILE|DIR)|REQUESTS_CA_BUNDLE|CURL_CA_BUNDLE|NODE_EXTRA_CA_CERTS|GIT_SSL_CAINFO|NODE_.+|NPM_.+|PNPM_.+|YARN_.+|BUN_.+|DENO_.+|MIX_.+|HEX_.+|ERL_.+|ELIXIR_.+|PYTHON.*|PIP_.+|POETRY_.+|UV_.+|VIRTUAL_ENV|JAVA_HOME|GRADLE_.+|MAVEN_.+|GO(?:ENV|FLAGS|PATH|ROOT|WORK)|CARGO_.+|RUST.+|RUBY.*|RBENV_.+|BUNDLE_.+|GEM_.+|PLAYWRIGHT_.+|CC|CXX)$/i
  @provider_env_key ~r/(?:^|_)(?:BASE_URL|ENDPOINT|HOST|PORT|REGION|PROFILE|CONFIG|ENV|MODE)(?:$|_)/i
  @repair_env_key ~r/^(?:(?:HTTP|HTTPS|ALL|NO)_PROXY|SSL_CERT_(?:FILE|DIR)|REQUESTS_CA_BUNDLE|CURL_CA_BUNDLE|NODE_EXTRA_CA_CERTS|GIT_SSL_CAINFO)$/i
  @repair_provider_env_key ~r/^(?!(?:CI|BUILD|RUNNER|JOB|WORKFLOW|STEP)_)[A-Z][A-Z0-9_]*_(?:BASE_URL|ENDPOINT|HOST|PORT|REGION|PROFILE)$/i

  if Mix.env() == :test do
    @spec merge_effective_environment_for_test(map(), map(), term()) :: map()
    def merge_effective_environment_for_test(inherited, command, os_type),
      do: merge_effective_environment(inherited, command, os_type)

    @spec executable_names_for_test(String.t(), String.t(), term()) :: [String.t()]
    def executable_names_for_test(executable, path_ext, os_type),
      do: executable_names(executable, path_ext, os_type)
  end

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
         {:ok, changed_paths} <- changed_paths_across_commits(workspace, base_head_sha, head_sha),
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
    local_paths =
      workspace
      |> Path.join(Path.join(@certificates_dir, "*.json"))
      |> Path.wildcard()

    durable_paths =
      workspace
      |> durable_controller_evidence_dir()
      |> then(&Path.join([&1, @durable_certificates_dir, "**", "*.json"]))
      |> Path.wildcard()

    (local_paths ++ durable_paths)
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
    |> Enum.uniq_by(& &1["controller_signature"])
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

  @type pending_miu_commit_state ::
          :no_pending_miu
          | {:no_committed_delta, map()}
          | {:committed_delta, map()}
          | {:invalid_delta, map()}
          | {:unknown, term()}

  @spec pending_miu_commit_state(Issue.t(), String.t()) :: pending_miu_commit_state()
  def pending_miu_commit_state(issue, workspace),
    do: pending_miu_commit_state(issue, workspace, [])

  @spec pending_miu_commit_state(Issue.t(), String.t(), keyword()) :: pending_miu_commit_state()
  def pending_miu_commit_state(%Issue{} = issue, workspace, opts)
      when is_binary(workspace) and is_list(opts) do
    with {:ok, compiled} <- structured_contract(issue),
         {:ok, head_sha} <- git(workspace, ["rev-parse", "HEAD"]),
         completed_ids <- valid_certified_miu_ids(issue, workspace, compiled, head_sha) |> MapSet.new(),
         miu_id when is_binary(miu_id) <-
           Enum.find(compiled.miu_ids, &(not MapSet.member?(completed_ids, &1))),
         %{} = miu <- Enum.find(compiled.contract["mius"], &(&1["id"] == miu_id)),
         {:ok, base_head_sha} <-
           pending_miu_base_sha(issue, workspace, compiled, head_sha, miu_id, opts),
         {:ok, committed_paths} <-
           changed_paths_across_commits(workspace, base_head_sha, head_sha),
         {:ok, worktree_paths} <- worktree_paths(workspace) do
      changed_paths = Enum.sort(Enum.uniq(committed_paths ++ worktree_paths))

      {in_scope_paths, out_of_scope_paths} =
        Enum.split_with(changed_paths, fn path ->
          pending_miu_path_allowed?(path, miu["write_scope"], compiled.denied_scope)
        end)

      snapshot = %{
        miu_id: miu_id,
        write_scope: miu["write_scope"],
        validations: miu["validations"],
        base_head_sha: base_head_sha,
        head_sha: head_sha,
        changed_paths: changed_paths,
        committed_paths: committed_paths,
        worktree_paths: worktree_paths,
        in_scope_paths: in_scope_paths,
        out_of_scope_paths: out_of_scope_paths
      }

      cond do
        out_of_scope_paths != [] -> {:invalid_delta, snapshot}
        committed_paths == [] -> {:no_committed_delta, snapshot}
        true -> {:committed_delta, snapshot}
      end
    else
      nil -> :no_pending_miu
      :none -> {:unknown, :pending_miu_base_unavailable}
      {:error, reason} -> {:unknown, reason}
      other -> {:unknown, {:pending_miu_state_unavailable, other}}
    end
  rescue
    error -> {:unknown, {:pending_miu_state_exception, Exception.message(error)}}
  end

  def pending_miu_commit_state(_issue, _workspace, _opts),
    do: {:unknown, :invalid_pending_miu_state_request}

  defp pending_miu_path_allowed?(path, write_scope, denied_scope) do
    Enum.any?(write_scope, &path_matches_scope?(path, &1)) and
      not Enum.any?(denied_scope, &path_matches_scope?(path, &1))
  end

  @spec pending_miu_committed_delta?(Issue.t(), String.t()) :: boolean()
  def pending_miu_committed_delta?(%Issue{} = issue, workspace) when is_binary(workspace) do
    match?({:committed_delta, _snapshot}, pending_miu_commit_state(issue, workspace))
  end

  def pending_miu_committed_delta?(_issue, _workspace), do: false

  defp pending_miu_base_sha(issue, workspace, compiled, head_sha, miu_id, opts) do
    if List.first(compiled.miu_ids) == miu_id do
      first_pending_miu_base_sha(issue, workspace, compiled, head_sha, opts)
    else
      certification_base_sha(issue, workspace, compiled, head_sha, miu_id)
    end
  end

  defp first_pending_miu_base_sha(issue, workspace, compiled, head_sha, opts) do
    case dispatch_certification_base_sha(issue, workspace, compiled, head_sha) do
      {:ok, base_head_sha} ->
        {:ok, base_head_sha}

      :none ->
        explicit_pending_miu_base_sha(
          workspace,
          compiled,
          head_sha,
          pending_miu_fallback_base_sha(workspace, compiled, head_sha, opts)
        )

      {:error, _reason} = error ->
        explicit_pending_miu_base_sha(workspace, compiled, head_sha, error)
    end
  end

  defp pending_miu_fallback_base_sha(workspace, compiled, head_sha, opts) do
    case Keyword.get(opts, :fallback_base_sha) do
      fallback_base_sha when is_binary(fallback_base_sha) and fallback_base_sha != "" ->
        if fallback_base_sha != head_sha and
             git_ancestor?(workspace, fallback_base_sha, head_sha) do
          {:ok, fallback_base_sha}
        else
          integration_certification_base_sha(workspace, compiled, head_sha)
        end

      _ ->
        integration_certification_base_sha(workspace, compiled, head_sha)
    end
  end

  defp explicit_pending_miu_base_sha(workspace, compiled, head_sha, fallback) do
    explicit_base_sha = compiled.contract["certification_base_sha"]

    if is_binary(explicit_base_sha) and explicit_base_sha != "" and
         git_ancestor?(workspace, explicit_base_sha, head_sha) do
      {:ok, explicit_base_sha}
    else
      fallback
    end
  end

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
    base_branch_merge_base(workspace, compiled.contract["base_branch"], head_sha)
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
    cond do
      preflight["issue_id"] != issue.id ->
        {:error, :dispatch_preflight_issue_id_mismatch}

      preflight["issue"] != issue.identifier ->
        {:error, :dispatch_preflight_issue_mismatch}

      preflight["branch"] != compiled.contract["integration_branch"] ->
        {:error, :dispatch_preflight_branch_mismatch}

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

  defp worktree_paths(workspace) do
    commands = [
      ["diff", "--name-only", "--no-renames", "--", ".", ":(exclude).orocsy/"],
      ["diff", "--cached", "--name-only", "--no-renames", "--", ".", ":(exclude).orocsy/"],
      ["ls-files", "--others", "--exclude-standard", "--", ".", ":(exclude).orocsy/"]
    ]

    Enum.reduce_while(commands, {:ok, []}, fn args, {:ok, paths} ->
      case git(workspace, args) do
        {:ok, output} ->
          current = String.split(output, "\n", trim: true)
          {:cont, {:ok, current ++ paths}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.sort(Enum.uniq(paths))}
      {:error, _reason} = error -> error
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
    ScopeAccessController.scope_pattern_matches?(path, scope)
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

  defp run_validations(issue, workspace, compiled, miu, head_sha) do
    Enum.reduce_while(miu["validations"], {:ok, []}, fn command, {:ok, events} ->
      environment = validation_environment_snapshot(workspace, command)

      fingerprint =
        validation_fingerprint(
          issue,
          compiled,
          miu["id"],
          head_sha,
          command,
          environment.environment_fingerprint
        )

      prior_product_failures = product_failure_count(workspace, issue, compiled, miu["id"], command)
      prior_infrastructure_failures = infrastructure_failure_count(workspace, issue, compiled, miu["id"], command)

      cond do
        product_attempt =
            product_failure_at_same_code_identity?(
              workspace,
              issue,
              compiled,
              miu["id"],
              head_sha,
              command,
              environment.repair_environment_fingerprint
            ) ->
          {:halt, {:blocked, {:unchanged_failed_validation, product_attempt["validation_fingerprint"]}}}

        failed_attempt = failed_fingerprint(workspace, fingerprint) ->
          reason =
            if infrastructure_failure?(failed_attempt) do
              {:unchanged_infrastructure_validation, fingerprint}
            else
              {:unchanged_failed_validation, fingerprint}
            end

          {:halt, {:blocked, reason}}

        infrastructure_failure_in_current_environment?(
          workspace,
          issue,
          compiled,
          miu["id"],
          command,
          environment.environment_fingerprint
        ) ->
          {:halt, {:blocked, {:unchanged_infrastructure_environment, miu["id"]}}}

        prior_infrastructure_failures >= 2 ->
          {:halt, {:blocked, {:infrastructure_retry_budget_exhausted, miu["id"]}}}

        true ->
          result =
            execute_validation(
              issue,
              workspace,
              compiled,
              miu["id"],
              head_sha,
              command,
              fingerprint,
              environment
            )

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

  defp execute_validation(
         issue,
         workspace,
         compiled,
         miu_id,
         head_sha,
         command,
         fingerprint,
         environment
       ) do
    started = System.monotonic_time(:millisecond)
    timeout_ms = compiled.contract["validation_timeout_ms"]

    {_raw_output, output, exit_code, timed_out?, launch_failed?} =
      run_command(workspace, command, timeout_ms, environment)

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
      "command" => environment.redacted_command,
      "command_hash" => "sha256:" <> sha256(command),
      "environment_fingerprint" => environment.environment_fingerprint,
      "repair_environment_fingerprint" => environment.repair_environment_fingerprint,
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

  defp run_command(workspace, command, timeout_ms, environment) do
    case OptionParser.split(command) do
      parts when parts != [] ->
        {_env, [executable | args]} = split_env_assignments(parts)

        executable =
          resolve_executable(
            executable,
            environment.executable_names,
            workspace,
            environment.executable_path,
            environment.os_type
          )

        port = open_command_port(executable, args, workspace, environment.child_environment)

        sensitive_values = environment.sensitive_values
        carry_bytes = max_sensitive_environment_value_bytes(sensitive_values)

        {raw_output, output, exit_code, timed_out?} =
          collect_command(
            port,
            timeout_ms,
            System.monotonic_time(:millisecond),
            "",
            "",
            "",
            sensitive_values,
            carry_bytes
          )

        {raw_output, output, exit_code, timed_out?, false}

      [] ->
        {"empty validation command", "empty validation command", 127, false, true}
    end
  rescue
    error -> {Exception.message(error), Exception.message(error), 127, false, true}
  end

  defp split_env_assignments(parts) do
    Enum.split_while(parts, &env_assignment?/1)
  end

  defp env_assignment?(part) when is_binary(part), do: Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=.*/, part)
  defp env_assignment?(_part), do: false

  defp validation_status(_command, _exit_code, _tests, _timed_out?, true),
    do: {"failed", "command_launch_failed"}

  defp validation_status(_command, _exit_code, _tests, true, false), do: {"failed", "command_timed_out"}

  defp validation_status(command, exit_code, tests, false, false) do
    cond do
      test_command?(command) and is_map(tests) and tests["collected"] == 0 ->
        {"failed", "zero_tests_collected"}

      test_command?(command) and is_map(tests) and tests["failed"] > 0 ->
        {"failed", "tests_failed"}

      exit_code != 0 ->
        {"failed", "command_failed"}

      not test_command?(command) ->
        {"passed", "passed"}

      tests == nil ->
        {"failed", "test_count_unavailable"}

      true ->
        {"passed", "passed"}
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

        match = Regex.run(~r/(\d+)\s+passed(?:,\s*(\d+)\s+failed)?\s+in\s+[\d.]+[sm]/i, output, capture: :all_but_first) ->
          [passed, failed] =
            match
            |> then(fn
              [passed] -> [passed, "0"]
              [passed, failed] -> [passed, failed]
            end)
            |> Enum.map(&String.to_integer/1)

          %{"collected" => passed + failed, "passed" => passed, "failed" => failed}

        match = Regex.run(~r/(\d+)\s+passed(?:,\s*(\d+)\s+failed)?\s+\([\d.]+[sm]\)/i, output, capture: :all_but_first) ->
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

  defp validation_fingerprint(
         issue,
         compiled,
         miu_id,
         head_sha,
         command,
         environment_fingerprint
       ) do
    [
      issue.id,
      issue.identifier,
      compiled.contract_hash,
      miu_id,
      head_sha,
      "sha256:" <> sha256(command),
      environment_fingerprint
    ]
    |> Enum.map_join("\n", &to_string/1)
    |> sha256()
    |> then(&("sha256:" <> &1))
  end

  defp validation_environment_snapshot(workspace, command) do
    command_env =
      command
      |> OptionParser.split()
      |> split_env_assignments()
      |> elem(0)
      |> environment_assignments()

    os_type = :os.type()
    effective_environment = merge_effective_environment(System.get_env(), command_env, os_type)
    sensitive_values = sensitive_values(effective_environment)

    %{
      child_environment: Enum.map(effective_environment, fn {key, value} -> "#{key}=#{value}" end),
      executable_names:
        executable_names(
          command |> OptionParser.split() |> split_env_assignments() |> elem(1) |> hd(),
          Map.get(effective_environment, "PATHEXT", ""),
          os_type
        ),
      executable_path: Map.get(effective_environment, "PATH", ""),
      os_type: os_type,
      environment_fingerprint: environment_fingerprint(workspace, effective_environment),
      repair_environment_fingerprint: repair_environment_fingerprint(effective_environment),
      sensitive_values: sensitive_values,
      redacted_command: redacted_validation_command(command, sensitive_values)
    }
  end

  defp environment_fingerprint(workspace, effective_environment) do
    lock_digest =
      ["pnpm-lock.yaml", "mix.lock", "package-lock.json", "yarn.lock"]
      |> Enum.find_value("none", fn name ->
        path = Path.join(workspace, name)
        if File.regular?(path), do: sha256(File.read!(path))
      end)

    ControllerEvidence.fingerprint(%{
      "environment" => validation_environment(effective_environment),
      "lock_digest" => lock_digest,
      "otp_release" => System.otp_release(),
      "runtime_version" => System.version()
    })
  end

  defp validation_environment(effective_environment) do
    effective_environment
    |> Enum.filter(fn {key, value} ->
      sensitive_environment_entry?(key, value) or Regex.match?(@validation_env_key, key) or
        Regex.match?(@provider_env_key, key)
    end)
    |> Map.new()
  end

  defp repair_environment_fingerprint(effective_environment) do
    effective_environment
    |> Enum.filter(fn {key, value} ->
      sensitive_environment_entry?(key, value) or Regex.match?(@repair_env_key, key) or
        Regex.match?(@repair_provider_env_key, key)
    end)
    |> Map.new()
    |> ControllerEvidence.fingerprint()
  end

  defp sensitive_env_key?(key),
    do:
      Regex.match?(@sensitive_env_key, key) or Regex.match?(@generic_key_env_key, key) or
        Regex.match?(@sensitive_proxy_env_key, key)

  defp sensitive_environment_entry?(key, value),
    do: sensitive_env_key?(key) or credential_bearing_uri?(value)

  defp credential_bearing_uri?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, userinfo: userinfo}
      when is_binary(scheme) and scheme != "" and is_binary(userinfo) and userinfo != "" ->
        true

      _other ->
        false
    end
  end

  defp credential_bearing_uri?(_value), do: false

  defp redacted_validation_command(command, sensitive_values) do
    {env_parts, command_parts} =
      command
      |> OptionParser.split()
      |> split_env_assignments()

    marker = redaction_marker(sensitive_values)

    redacted_env =
      Enum.map(env_parts, fn assignment ->
        [key, _value] = String.split(assignment, "=", parts: 2)
        "#{key}=#{marker}"
      end)

    display_command =
      redacted_env
      |> Kernel.++(command_parts)
      |> Enum.map_join(" ", &inspect/1)

    {redacted, ""} = redact_stream_prefix(display_command, sensitive_values, 0)
    redacted
  end

  defp environment_assignments(assignments) do
    assignments
    |> Enum.map(fn assignment ->
      [key, value] = String.split(assignment, "=", parts: 2)
      {key, value}
    end)
    |> Map.new()
  end

  defp merge_effective_environment(inherited, command, {:win32, _name}) do
    inherited
    |> normalize_windows_environment()
    |> Map.merge(normalize_windows_environment(command))
  end

  defp merge_effective_environment(inherited, command, _unix),
    do: Map.merge(inherited, command)

  defp normalize_windows_environment(environment) do
    Map.new(environment, fn {key, value} -> {String.upcase(key), value} end)
  end

  defp executable_names(executable, path_ext, {:win32, _name}) do
    if Path.extname(executable) == "" do
      path_ext
      |> String.split(";", trim: true)
      |> Enum.map(fn extension ->
        extension = if String.starts_with?(extension, "."), do: extension, else: "." <> extension
        executable <> extension
      end)
      |> case do
        [] -> Enum.map(~w(.COM .EXE .BAT .CMD), &(executable <> &1))
        names -> names
      end
    else
      [executable]
    end
  end

  defp executable_names(executable, _path_ext, _unix), do: [executable]

  defp sensitive_values(environment) do
    environment
    |> Enum.filter(fn {key, value} ->
      is_binary(value) and value != "" and sensitive_environment_entry?(key, value)
    end)
    |> Enum.sort_by(fn {key, value} -> {-byte_size(value), key} end)
  end

  defp max_sensitive_environment_value_bytes(sensitive_values) do
    sensitive_values
    |> Enum.map(fn {_key, value} -> byte_size(value) end)
    |> Enum.max(fn -> 0 end)
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

  defp product_failure_at_same_code_identity?(
         workspace,
         issue,
         compiled,
         miu_id,
         head_sha,
         command,
         current_repair_environment
       ) do
    command_hash = "sha256:" <> sha256(command)

    workspace
    |> trusted_attempts()
    |> Enum.find(fn attempt ->
      product_failure?(attempt) and
        attempt["issue"] == issue.identifier and
        attempt["contract_hash"] == compiled.contract_hash and
        attempt["miu_id"] == miu_id and
        attempt["head_sha"] == head_sha and
        attempt["command_hash"] == command_hash and
        product_failure_blocks_environment_retry?(attempt, current_repair_environment)
    end)
  end

  defp product_failure_blocks_environment_retry?(%{"reason_class" => "command_failed"} = attempt, current) do
    case attempt["repair_environment_fingerprint"] do
      previous when is_binary(previous) -> previous == current
      _missing_from_older_evidence -> true
    end
  end

  defp product_failure_blocks_environment_retry?(_attempt, _current), do: true

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

  defp infrastructure_failure_in_current_environment?(
         workspace,
         issue,
         compiled,
         miu_id,
         command,
         current_environment
       ) do
    command_hash = "sha256:" <> sha256(command)

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

  def reconcile_runtime_corrections(issue, workspace, miu_id, {:error, _reason} = result) do
    head_sha = git_value(workspace, ["rev-parse", "HEAD"])

    if existing_controller_validation_correction?(workspace, miu_id, head_sha) do
      :ok
    else
      case Workspace.create_correction_in_workspace(
             workspace,
             issue,
             validation_correction_attrs(issue, workspace, miu_id, head_sha, result)
           ) do
        {:ok, _correction} -> :ok
        {:error, reason} -> {:error, {:validation_correction_write_failed, reason}}
      end
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

  defp validation_correction_attrs(issue, _workspace, "__final__", head_sha, result) do
    %{
      source: @authority,
      source_status: "blocked",
      summary: "Final runtime certification did not complete",
      findings:
        ["Controller result: #{inspect(result)}", correction_scope_finding(issue, "__final__")]
        |> Enum.reject(&is_nil/1),
      required_corrections: [
        "Do not create a post-certification commit. An operator must correct the certificate or environment at the same head, or revise the Runtime Contract with an explicit repair MIU."
      ],
      next_action: "block",
      guard: %{"miu_id" => "__final__", "head_sha" => head_sha}
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

  defp resolve_executable(executable, names, workspace, executable_path, os_type) do
    resolved =
      if String.starts_with?(executable, "./") or Path.type(executable) == :absolute or
           String.contains?(executable, "/") do
        Enum.find_value(names, fn name ->
          name
          |> Path.expand(workspace)
          |> executable_path_candidate(os_type)
        end)
      else
        find_executable(names, executable_path, workspace, os_type)
      end

    resolved || raise "validation executable not found: #{executable}"
  end

  defp find_executable(names, executable_path, workspace, os_type) do
    executable_path
    |> String.split(path_separator())
    |> Enum.find_value(fn
      "" -> executable_candidate(workspace, names, workspace, os_type)
      directory -> executable_candidate(directory, names, workspace, os_type)
    end)
  end

  defp executable_candidate(directory, names, workspace, os_type) do
    directory =
      if Path.type(directory) == :relative,
        do: Path.expand(directory, workspace),
        else: directory

    Enum.find_value(names, fn name ->
      directory
      |> Path.join(name)
      |> executable_path_candidate(os_type)
    end)
  end

  defp executable_path_candidate(candidate, os_type) do
    case {os_type, File.stat(candidate)} do
      {{:win32, _name}, {:ok, %{type: :regular}}} -> candidate
      {_os, {:ok, %{type: :regular, mode: mode}}} when Bitwise.band(mode, 0o111) != 0 -> candidate
      _missing_or_non_regular -> false
    end
  end

  defp path_separator do
    case :os.type() do
      {:win32, _name} -> ";"
      _unix -> ":"
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

  defp collect_command(
         port,
         timeout_ms,
         started_ms,
         raw_output,
         output,
         redaction_tail,
         sensitive_values,
         carry_bytes
       ) do
    remaining_ms = max(0, timeout_ms - (System.monotonic_time(:millisecond) - started_ms))

    receive do
      {^port, {:data, data}} ->
        {redacted, redaction_tail} =
          redaction_tail
          |> Kernel.<>(data)
          |> redact_stream_prefix(sensitive_values, carry_bytes)

        collect_command(
          port,
          timeout_ms,
          started_ms,
          bounded_capture(raw_output <> data, @max_capture_bytes),
          bounded_capture(output <> redacted, @max_capture_bytes),
          redaction_tail,
          sensitive_values,
          carry_bytes
        )

      {^port, {:exit_status, exit_code}} ->
        output = flush_redaction_tail(output, redaction_tail, sensitive_values)
        {String.replace_invalid(raw_output), String.replace_invalid(output), exit_code, false}
    after
      remaining_ms ->
        Port.close(port)
        timeout_output = "\n[validation timed out after #{timeout_ms}ms]\n"
        output = flush_redaction_tail(output, redaction_tail, sensitive_values)

        {
          raw_output
          |> Kernel.<>(timeout_output)
          |> bounded_capture(@max_capture_bytes)
          |> String.replace_invalid(),
          output
          |> Kernel.<>(timeout_output)
          |> bounded_capture(@max_capture_bytes)
          |> String.replace_invalid(),
          124,
          true
        }
    end
  end

  defp redact_stream_prefix(output, [], _carry_bytes), do: {output, ""}

  defp redact_stream_prefix(output, sensitive_values, carry_bytes) do
    redact_stream_prefix(
      output,
      sensitive_values,
      carry_bytes,
      redaction_marker(sensitive_values),
      []
    )
  end

  defp redact_stream_prefix("", _sensitive_values, _carry_bytes, _marker, output),
    do: {IO.iodata_to_binary(Enum.reverse(output)), ""}

  defp redact_stream_prefix(input, _sensitive_values, carry_bytes, _marker, output)
       when byte_size(input) <= carry_bytes do
    {IO.iodata_to_binary(Enum.reverse(output)), input}
  end

  defp redact_stream_prefix(input, sensitive_values, carry_bytes, marker, output) do
    case sensitive_prefix(input, sensitive_values) do
      {_key, value} ->
        value_bytes = byte_size(value)
        rest_bytes = byte_size(input) - value_bytes
        rest = binary_part(input, value_bytes, rest_bytes)

        redact_stream_prefix(
          rest,
          sensitive_values,
          carry_bytes,
          marker,
          [marker | output]
        )

      nil ->
        emit_bytes = safe_plain_prefix_bytes(input, sensitive_values, carry_bytes)
        emitted = binary_part(input, 0, emit_bytes)
        rest = binary_part(input, emit_bytes, byte_size(input) - emit_bytes)

        redact_stream_prefix(
          rest,
          sensitive_values,
          carry_bytes,
          marker,
          [emitted | output]
        )
    end
  end

  defp redaction_marker(sensitive_values) do
    Enum.find(["[REDACTED]", "<redacted>", "***", ""], fn candidate ->
      Enum.all?(sensitive_values, fn {_key, value} ->
        :binary.match(candidate, value) == :nomatch
      end)
    end)
  end

  defp sensitive_prefix(input, sensitive_values) do
    Enum.find(sensitive_values, fn {_key, value} ->
      value_bytes = byte_size(value)
      byte_size(input) >= value_bytes and binary_part(input, 0, value_bytes) == value
    end)
  end

  defp safe_plain_prefix_bytes(input, sensitive_values, carry_bytes) do
    max_emit = byte_size(input) - carry_bytes

    sensitive_values
    |> Enum.reduce(nil, fn {_key, value}, earliest ->
      case :binary.match(input, value) do
        {index, _length} when is_nil(earliest) or index < earliest -> index
        _ -> earliest
      end
    end)
    |> case do
      nil -> max_emit
      index -> min(max_emit, index)
    end
  end

  defp flush_redaction_tail(output, redaction_tail, sensitive_values) do
    {redacted_tail, ""} = redact_stream_prefix(redaction_tail, sensitive_values, 0)
    bounded_capture(output <> redacted_tail, @max_capture_bytes)
  end

  defp bounded_capture(output, max_bytes) when byte_size(output) <= max_bytes, do: output

  defp bounded_capture(output, max_bytes) do
    keep = max_bytes - byte_size("...[earlier output truncated]...\n")
    "...[earlier output truncated]...\n" <> binary_part(output, byte_size(output) - keep, keep)
  end

  defp current_certificate(workspace, issue, miu_id) do
    with {:ok, compiled} <- structured_contract(issue),
         {:ok, head_sha} <- git(workspace, ["rev-parse", "HEAD"]),
         certificate when is_map(certificate) <-
           issue
           |> valid_miu_certificates(workspace, compiled, head_sha)
           |> Enum.find(&(&1["miu_id"] == miu_id and &1["head_sha"] == head_sha)) do
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
    filename = safe_id(miu_id) <> ".json"
    body = Jason.encode!(certificate, pretty: true) <> "\n"

    durable_path =
      Path.join([
        durable_controller_evidence_dir(workspace),
        @durable_certificates_dir,
        durable_certificate_namespace(certificate),
        filename
      ])

    local_path = Path.join([workspace, @certificates_dir, filename])
    :ok = atomic_write_controller_evidence(durable_path, body)
    :ok = atomic_write_controller_evidence(local_path, body)
    :ok
  end

  defp durable_controller_evidence_dir(workspace) do
    root =
      Application.get_env(:symphony_elixir, :controller_evidence_state_dir) ||
        System.get_env("SYMPHONY_CONTROLLER_EVIDENCE_STATE_DIR") ||
        Path.join(Path.dirname(workspace), ".orocsy-controller-evidence")

    root
    |> Path.expand()
    |> Path.join(sha256(Path.expand(workspace)))
  end

  defp durable_certificate_namespace(certificate) do
    [
      certificate["issue_id"],
      certificate["issue"],
      certificate["branch"],
      certificate["contract_hash"],
      certificate["issue_revision"]
    ]
    |> Enum.map_join(<<0>>, &to_string/1)
    |> sha256()
  end

  defp atomic_write_controller_evidence(path, body) do
    directory = Path.dirname(path)
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)

    temporary_path =
      path <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"

    with :ok <- File.write(temporary_path, body, [:exclusive]),
         :ok <- File.chmod(temporary_path, 0o600),
         :ok <- File.rename(temporary_path, path) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(temporary_path)
        error
    end
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
