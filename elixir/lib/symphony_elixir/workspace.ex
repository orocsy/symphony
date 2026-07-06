defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, IssueRequirements, PathSafety, PromptBuilder, SSH}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, worker_host),
           :ok <- maybe_reconcile_issue_branch(workspace, issue_or_identifier, worker_host),
           :ok <- maybe_write_issue_requirements(workspace, issue_or_identifier, worker_host) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  @spec path_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def path_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_or_identifier
    |> issue_context()
    |> Map.get(:issue_identifier)
    |> safe_identifier()
    |> workspace_path_for_issue(worker_host)
  end

  @spec blocking_correction_for_issue?(map() | String.t() | nil, worker_host()) :: boolean()
  def blocking_correction_for_issue?(issue_or_identifier, worker_host \\ nil) do
    with {:ok, workspace} <- path_for_issue(issue_or_identifier, worker_host) do
      blocking_correction_in_workspace?(workspace, worker_host)
    else
      _ -> false
    end
  end

  def blocking_correction_in_workspace?(workspace, worker_host \\ nil)

  @spec blocking_correction_in_workspace?(Path.t(), worker_host()) :: boolean()
  def blocking_correction_in_workspace?(workspace, nil) when is_binary(workspace) do
    with :ok <- validate_workspace_path(workspace, nil),
         true <- File.dir?(workspace) do
      workspace
      |> local_correction_files()
      |> Enum.any?(&blocking_correction_file?/1)
    else
      _ -> false
    end
  end

  def blocking_correction_in_workspace?(workspace, worker_host)
      when is_binary(workspace) and is_binary(worker_host) do
    with :ok <- validate_workspace_path(workspace, worker_host),
         {:ok, {output, 0}} <- run_remote_command(worker_host, remote_blocking_correction_script(workspace), Config.settings!().hooks.timeout_ms) do
      output
      |> IO.iodata_to_binary()
      |> String.split("\n", trim: true)
      |> Enum.member?("blocked")
    else
      _ -> false
    end
  end

  def create_correction_in_workspace(workspace, issue_or_identifier, attrs, worker_host \\ nil)

  @spec create_correction_in_workspace(Path.t(), map() | String.t() | nil, map(), worker_host()) ::
          {:ok, map()} | {:error, term()}
  def create_correction_in_workspace(workspace, issue_or_identifier, attrs, nil)
      when is_binary(workspace) and is_map(attrs) do
    issue_context = issue_context(issue_or_identifier)

    with :ok <- validate_workspace_path(workspace, nil),
         true <- File.dir?(workspace) do
      correction = build_correction(issue_context, attrs)
      artifacts = write_local_correction_files(workspace, correction)
      correction = Map.put(correction, "artifacts", artifacts)
      write_local_correction_json(workspace, artifacts["json"], correction)

      {:ok, correction}
    else
      false -> {:error, {:workspace_missing, workspace}}
      {:error, reason} -> {:error, reason}
    end
  end

  def create_correction_in_workspace(workspace, _issue_or_identifier, _attrs, worker_host)
      when is_binary(workspace) and is_binary(worker_host) do
    {:error, {:remote_correction_write_not_supported, worker_host, workspace}}
  end

  @spec open_blocking_corrections_in_workspace(Path.t()) :: [map()]
  def open_blocking_corrections_in_workspace(workspace) when is_binary(workspace) do
    with :ok <- validate_workspace_path(workspace, nil),
         true <- File.dir?(workspace) do
      workspace
      |> local_correction_files()
      |> Enum.flat_map(&read_local_blocking_correction/1)
      |> newest_corrections_first()
    else
      _ -> []
    end
  end

  @spec resolve_blocking_corrections_in_workspace(Path.t(), String.t()) :: :ok | {:error, term()}
  def resolve_blocking_corrections_in_workspace(workspace, resolution_summary)
      when is_binary(workspace) and is_binary(resolution_summary) do
    with :ok <- validate_workspace_path(workspace, nil),
         true <- File.dir?(workspace) do
      now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      workspace
      |> local_correction_files()
      |> Enum.each(fn path ->
        case read_local_blocking_correction(path) do
          [%{"correction_id" => _id} = correction] ->
            resolved =
              correction
              |> Map.put("status", "resolved")
              |> Map.put("resolved_at", now)
              |> Map.put("resolution_summary", resolution_summary)

            File.write!(path, Jason.encode!(resolved, pretty: true) <> "\n")

          _ ->
            :ok
        end
      end)

      :ok
    else
      false -> {:error, {:workspace_missing, workspace}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec classify_blocking_corrections_in_workspace(Path.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def classify_blocking_corrections_in_workspace(workspace, classification, summary)
      when is_binary(workspace) and is_binary(classification) and is_binary(summary) do
    with :ok <- validate_workspace_path(workspace, nil),
         true <- File.dir?(workspace) do
      now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      workspace
      |> local_correction_files()
      |> Enum.each(fn path ->
        case read_local_blocking_correction(path) do
          [%{"correction_id" => _id} = correction] ->
            classified =
              correction
              |> Map.put("classification", classification)
              |> Map.put("classification_summary", summary)
              |> Map.put("classified_at", now)

            File.write!(path, Jason.encode!(classified, pretty: true) <> "\n")

          _ ->
            :ok
        end
      end)

      :ok
    else
      false -> {:error, {:workspace_missing, workspace}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec resolve_blocking_corrections_by_id_in_workspace(Path.t(), [String.t()], String.t()) ::
          :ok | {:error, term()}
  def resolve_blocking_corrections_by_id_in_workspace(workspace, correction_ids, resolution_summary)
      when is_binary(workspace) and is_list(correction_ids) and is_binary(resolution_summary) do
    with :ok <- validate_workspace_path(workspace, nil),
         true <- File.dir?(workspace) do
      now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      selected_ids = correction_id_set(correction_ids)

      workspace
      |> local_correction_files()
      |> Enum.each(fn path ->
        case read_local_blocking_correction(path) do
          [%{"correction_id" => id} = correction] ->
            if MapSet.member?(selected_ids, id) do
              resolved =
                correction
                |> Map.put("status", "resolved")
                |> Map.put("resolved_at", now)
                |> Map.put("resolution_summary", resolution_summary)

              File.write!(path, Jason.encode!(resolved, pretty: true) <> "\n")
            end

          _ ->
            :ok
        end
      end)

      :ok
    else
      false -> {:error, {:workspace_missing, workspace}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec classify_blocking_corrections_by_id_in_workspace(Path.t(), [String.t()], String.t(), String.t()) ::
          :ok | {:error, term()}
  def classify_blocking_corrections_by_id_in_workspace(workspace, correction_ids, classification, summary)
      when is_binary(workspace) and is_list(correction_ids) and is_binary(classification) and is_binary(summary) do
    with :ok <- validate_workspace_path(workspace, nil),
         true <- File.dir?(workspace) do
      now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      selected_ids = correction_id_set(correction_ids)

      workspace
      |> local_correction_files()
      |> Enum.each(fn path ->
        case read_local_blocking_correction(path) do
          [%{"correction_id" => id} = correction] ->
            if MapSet.member?(selected_ids, id) do
              classified =
                correction
                |> Map.put("classification", classification)
                |> Map.put("classification_summary", summary)
                |> Map.put("classified_at", now)

              File.write!(path, Jason.encode!(classified, pretty: true) <> "\n")
            end

          _ ->
            :ok
        end
      end)

      :ok
    else
      false -> {:error, {:workspace_missing, workspace}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp correction_id_set(correction_ids) do
    correction_ids
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  defp ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            maybe_run_before_remove_hook(workspace, nil)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host)

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    safe_id = safe_identifier(identifier)

    case workspace_path_for_issue(safe_id, worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)

    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(safe_id, nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host)
        end

      false ->
        :ok
    end
  end

  defp maybe_write_issue_requirements(_workspace, _issue, worker_host) when is_binary(worker_host), do: :ok

  defp maybe_write_issue_requirements(workspace, %{} = issue, nil) do
    case IssueRequirements.write_workspace_files(workspace, issue) do
      {:ok, _requirements} ->
        :ok

      {:error, :no_issue_requirements} ->
        :ok

      {:error, {:missing_issue_requirements, _missing} = reason} ->
        Logger.warning("Skipping partial issue requirements for workspace=#{workspace}: #{inspect(reason)}")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_write_issue_requirements(_workspace, _issue, _worker_host), do: :ok

  defp maybe_reconcile_issue_branch(_workspace, _issue, worker_host) when is_binary(worker_host), do: :ok

  defp maybe_reconcile_issue_branch(workspace, issue_or_identifier, nil) do
    branch = issue_branch_name(issue_or_identifier)

    cond do
      branch == "" ->
        :ok

      not File.dir?(Path.join(workspace, ".git")) ->
        :ok

      git_dirty?(workspace) ->
        Logger.info("Skipping issue branch reconciliation for dirty workspace=#{workspace} branch=#{branch}")
        :ok

      true ->
        reconcile_local_issue_branch(workspace, branch, issue_or_identifier)
    end
  end

  defp reconcile_local_issue_branch(workspace, branch, issue_or_identifier) do
    remote_ref = "refs/remotes/origin/#{branch}"

    case git_command(workspace, ["fetch", "origin", "+refs/heads/#{branch}:#{remote_ref}"]) do
      {_output, 0} ->
        switch_to_reconciled_branch(workspace, branch)

      {output, status} ->
        Logger.debug("Issue branch fetch skipped workspace=#{workspace} branch=#{branch} status=#{status} output=#{inspect(sanitize_hook_output_for_log(output))}")
        switch_to_new_or_existing_issue_branch(workspace, branch, issue_or_identifier)
    end
  rescue
    error ->
      Logger.debug("Issue branch reconciliation skipped workspace=#{workspace} branch=#{branch} error=#{inspect(error)}")
      :ok
  end

  defp switch_to_reconciled_branch(workspace, branch) do
    result =
      if git_local_branch_exists?(workspace, branch) do
        git_command(workspace, ["switch", branch])
      else
        git_command(workspace, ["switch", "--track", "-c", branch, "origin/#{branch}"])
      end

    case result do
      {_output, 0} ->
        _ = git_command(workspace, ["branch", "--set-upstream-to", "origin/#{branch}", branch])
        fast_forward_reconciled_branch(workspace, branch)

      {output, status} ->
        {:error, {:issue_branch_switch_failed, branch, status, output}}
    end
  end

  defp fast_forward_reconciled_branch(workspace, branch) do
    case git_command(workspace, ["merge", "--ff-only", "origin/#{branch}"]) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:issue_branch_fast_forward_failed, branch, status, output}}
    end
  end

  defp switch_to_new_or_existing_issue_branch(workspace, branch, issue_or_identifier) do
    cond do
      git_local_branch_exists?(workspace, branch) ->
        case git_command(workspace, ["switch", branch]) do
          {_output, 0} -> maybe_unset_main_upstream(workspace, branch)
          {output, status} -> {:error, {:issue_branch_switch_failed, branch, status, output}}
        end

      start_ref = issue_branch_start_ref(workspace, issue_or_identifier) ->
        case git_command(workspace, ["switch", "--no-track", "-c", branch, start_ref]) do
          {_output, 0} -> maybe_unset_main_upstream(workspace, branch)
          {output, status} -> {:error, {:issue_branch_create_failed, branch, start_ref, status, output}}
        end

      true ->
        :ok
    end
  end

  defp issue_branch_start_ref(workspace, issue_or_identifier) do
    base_candidates = issue_branch_base_candidates(issue_or_identifier)

    Enum.each(base_candidates, &fetch_branch_ref(workspace, &1))

    base_candidates
    |> Enum.flat_map(&["origin/#{&1}", &1])
    |> Enum.concat(["origin/main", "main", "origin/master", "master"])
    |> Enum.find(&git_ref_exists?(workspace, &1))
  end

  defp fetch_branch_ref(_workspace, ""), do: :ok

  defp fetch_branch_ref(workspace, branch) when is_binary(branch) do
    _ = git_command(workspace, ["fetch", "origin", "+refs/heads/#{branch}:refs/remotes/origin/#{branch}"])
    :ok
  rescue
    _error -> :ok
  end

  defp issue_branch_base_candidates(issue_or_identifier) do
    issue_or_identifier
    |> issue_branch_base_names()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&clean_branch_name/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp issue_branch_base_names(%{description: description}) when is_binary(description) do
    description_branch_base_names(description)
  end

  defp issue_branch_base_names(%{"description" => description}) when is_binary(description) do
    description_branch_base_names(description)
  end

  defp issue_branch_base_names(%{base_branch: base_branch, integration_branch: integration_branch}) do
    [base_branch, integration_branch]
  end

  defp issue_branch_base_names(%{"base_branch" => base_branch, "integration_branch" => integration_branch}) do
    [base_branch, integration_branch]
  end

  defp issue_branch_base_names(_issue_or_identifier), do: []

  defp description_branch_base_names(description) do
    [
      description_scalar_section(description, "Base Branch"),
      description_scalar_section(description, "Integration Branch"),
      description_contract_field(description, ["Base", "Base Branch", "Base and PR target"]),
      description_contract_field(description, ["Integration Branch", "Integration"])
    ]
  end

  defp description_scalar_section(description, heading) do
    case description_section_body(description, heading) do
      "" ->
        nil

      body ->
        body
        |> String.split("\n")
        |> Enum.map(fn line ->
          line
          |> String.trim()
          |> String.trim_leading("*")
          |> String.trim_leading("-")
          |> String.trim()
          |> String.trim("`")
        end)
        |> Enum.reject(&(&1 == ""))
        |> List.first()
    end
  end

  defp description_contract_field(description, labels) do
    description
    |> description_section_body("Branch / PR Contract")
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      line = clean_contract_line(line)
      downcased = String.downcase(line)

      Enum.find_value(labels, fn label ->
        prefix = "#{String.downcase(label)}:"

        if String.starts_with?(downcased, prefix) do
          line
          |> String.slice(String.length(prefix), String.length(line) - String.length(prefix))
          |> clean_contract_value()
        end
      end)
    end)
  end

  defp description_section_body(description, heading) do
    pattern = ~r/^##\s+#{Regex.escape(heading)}\s*\n(.*?)(?=^(?:##|###)\s+|\z)/ms

    case Regex.run(pattern, description || "", capture: :all_but_first) do
      [body] -> body
      _ -> ""
    end
  end

  defp clean_contract_line(line) do
    line
    |> String.trim()
    |> String.trim_leading("*")
    |> String.trim_leading("-")
    |> String.trim()
  end

  defp clean_contract_value(value) do
    value = String.trim(value || "")

    value =
      case Regex.run(~r/`([^`]+)`/, value, capture: :all_but_first) do
        [code] -> code
        _ -> value
      end

    branch =
      value
      |> String.trim()
      |> String.split(~r/\s+/, parts: 2)
      |> List.first()
      |> String.trim("`")
      |> String.trim_trailing(".")
      |> String.trim_trailing(",")
      |> String.trim_trailing(";")
      |> String.trim()

    case branch do
      "" -> nil
      branch -> branch
    end
  end

  defp maybe_unset_main_upstream(workspace, branch) do
    case git_command(workspace, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]) do
      {upstream, 0} ->
        upstream = String.trim(upstream)

        if upstream in ["origin/main", "origin/master", "main", "master"] do
          _ = git_command(workspace, ["branch", "--unset-upstream", branch])
        end

        :ok

      {_output, _status} ->
        :ok
    end
  end

  defp git_dirty?(workspace) do
    case git_command(workspace, ["status", "--porcelain=v1"]) do
      {"", 0} -> false
      {_status, 0} -> true
      {_output, _status} -> true
    end
  rescue
    _error -> true
  end

  defp git_local_branch_exists?(workspace, branch) do
    case git_command(workspace, ["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"]) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  rescue
    _error -> false
  end

  defp git_ref_exists?(workspace, ref) do
    case git_command(workspace, ["rev-parse", "--verify", "--quiet", ref]) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  rescue
    _error -> false
  end

  defp issue_branch_name(%{description: description, branch_name: branch}) when is_binary(description) and is_binary(branch) do
    description_existing_pr_branch(description) || clean_branch_name(branch)
  end

  defp issue_branch_name(%{"description" => description, "branch_name" => branch})
       when is_binary(description) and is_binary(branch) do
    description_existing_pr_branch(description) || clean_branch_name(branch)
  end

  defp issue_branch_name(%{branch_name: branch}) when is_binary(branch), do: clean_branch_name(branch)
  defp issue_branch_name(%{"branch_name" => branch}) when is_binary(branch), do: clean_branch_name(branch)
  defp issue_branch_name(%{"branch" => branch}) when is_binary(branch), do: clean_branch_name(branch)
  defp issue_branch_name(_issue), do: ""

  defp description_existing_pr_branch(description) do
    if shared_existing_branch_contract?(description) do
      [
        description_scalar_section(description, "Integration Branch"),
        description_scalar_section(description, "Base Branch"),
        description_contract_field(description, ["Integration Branch", "Branch", "Base"])
      ]
      |> Enum.find_value(fn
        value when is_binary(value) ->
          branch = clean_branch_name(clean_contract_value(value) || value)
          if branch == "", do: nil, else: branch

        _ ->
          nil
      end)
    end
  end

  defp shared_existing_branch_contract?(description) do
    normalized = String.downcase(description || "")

    String.contains?(normalized, "use the existing branch/pr") or
      String.contains?(normalized, "existing branch/pr only") or
      String.contains?(normalized, "same shared branch") or
      String.contains?(normalized, "shared branch/pr")
  end

  defp git_command(workspace, args) when is_binary(workspace) and is_list(args) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    task =
      Task.async(fn ->
        System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {"git command timed out after #{timeout_ms}ms", 124}
    end
  end

  defp clean_branch_name(branch) do
    branch = String.trim(branch)

    if String.contains?(branch, ["\n", "\r", <<0>>]) do
      ""
    else
      branch
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms
    command = PromptBuilder.render_issue_template(command, issue_context)

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms
    command = PromptBuilder.render_issue_template(command, issue_context)

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    case run_remote_command(worker_host, "cd #{shell_escape(workspace)} && #{command}", timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp local_correction_files(workspace) do
    workspace
    |> Path.join(".orocsy/delivery/inbox/correction_*.json")
    |> Path.wildcard()
  end

  defp blocking_correction_file?(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = correction} <- Jason.decode(body) do
      open_blocking_correction?(correction)
    else
      _ -> false
    end
  end

  defp read_local_blocking_correction(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = correction} <- Jason.decode(body),
         true <- open_blocking_correction?(correction) do
      [Map.put(correction, "path", path)]
    else
      _ -> []
    end
  end

  defp newest_corrections_first(corrections) do
    Enum.sort_by(corrections, &correction_sort_key/1, :desc)
  end

  defp correction_sort_key(%{} = correction) do
    cond do
      is_binary(correction["created_at"]) and correction["created_at"] != "" ->
        correction["created_at"]

      is_binary(correction["correction_id"]) and correction["correction_id"] != "" ->
        correction["correction_id"]

      is_binary(correction["path"]) ->
        Path.basename(correction["path"])

      true ->
        ""
    end
  end

  defp correction_sort_key(_correction), do: ""

  defp open_blocking_correction?(%{} = correction) do
    normalize_correction_field(correction["status"]) == "open" and
      normalize_correction_field(correction["next_action"]) in ["block", "retry", "escalate"] and
      is_nil(correction["resolved_at"])
  end

  defp normalize_correction_field(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_correction_field(_value), do: ""

  defp remote_blocking_correction_script(workspace) do
    [
      remote_shell_assign("workspace", workspace),
      "inbox=\"$workspace/.orocsy/delivery/inbox\"",
      "if [ ! -d \"$inbox\" ]; then exit 0; fi",
      "for correction in \"$inbox\"/correction_*.json; do",
      "  [ -f \"$correction\" ] || continue",
      "  if grep -Eq '\"status\"[[:space:]]*:[[:space:]]*\"open\"' \"$correction\" && grep -Eq '\"next_action\"[[:space:]]*:[[:space:]]*\"(block|retry|escalate)\"' \"$correction\" && grep -Eq '\"resolved_at\"[[:space:]]*:[[:space:]]*null' \"$correction\"; then",
      "    printf '%s\\n' blocked",
      "    exit 0",
      "  fi",
      "done"
    ]
    |> Enum.join("\n")
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp build_correction(issue_context, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    correction_id = correction_id(now)

    %{
      "schema_version" => 1,
      "correction_id" => correction_id,
      "status" => "open",
      "source" => Map.get(attrs, :source, "symphony.runtime"),
      "source_status" => Map.get(attrs, :source_status, "failed"),
      "summary" => Map.get(attrs, :summary, "Symphony runtime parked this issue."),
      "findings" => string_list(Map.get(attrs, :findings, [])),
      "required_corrections" => string_list(Map.get(attrs, :required_corrections, [])),
      "next_action" => normalize_next_action(Map.get(attrs, :next_action, "block")),
      "guard" => Map.get(attrs, :guard, %{}),
      "issue" => issue_context.issue_identifier,
      "issue_id" => issue_context.issue_id,
      "created_at" => now,
      "resolved_at" => nil,
      "resolution_summary" => ""
    }
  end

  defp write_local_correction_files(workspace, correction) do
    inbox = Path.join(workspace, ".orocsy/delivery/inbox")
    File.mkdir_p!(inbox)

    stem = correction["correction_id"]
    json_relative = ".orocsy/delivery/inbox/#{stem}.json"
    markdown_relative = ".orocsy/delivery/inbox/#{stem}.md"

    File.write!(Path.join(workspace, markdown_relative), render_correction_markdown(correction))

    %{
      "json" => json_relative,
      "markdown" => markdown_relative
    }
  end

  defp write_local_correction_json(workspace, relative_path, correction) do
    workspace
    |> Path.join(relative_path)
    |> File.write!(Jason.encode!(correction, pretty: true) <> "\n")
  end

  defp render_correction_markdown(correction) do
    findings = correction["findings"] || []
    required_corrections = correction["required_corrections"] || []

    [
      "# Correction #{correction["correction_id"]}",
      "",
      "Status: #{correction["status"]}",
      "Source: #{correction["source"]}",
      "Next action: #{correction["next_action"]}",
      "",
      "## Summary",
      "",
      correction["summary"],
      "",
      "## Findings",
      "",
      render_markdown_list(findings, "None recorded"),
      "",
      "## Required Corrections",
      "",
      render_markdown_list(required_corrections, "Determine the smallest safe recovery step before continuing.")
    ]
    |> List.flatten()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp render_markdown_list([], fallback), do: ["- #{fallback}"]
  defp render_markdown_list(items, _fallback), do: Enum.map(items, &"- #{&1}")

  defp string_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp string_list(value) when is_binary(value), do: string_list([value])
  defp string_list(_value), do: []

  defp normalize_next_action(next_action) when is_binary(next_action) do
    case next_action |> String.trim() |> String.downcase() do
      action when action in ["block", "retry", "escalate"] -> action
      _ -> "block"
    end
  end

  defp normalize_next_action(_next_action), do: "block"

  defp correction_id(iso8601) do
    timestamp =
      iso8601
      |> String.replace(~r/[^0-9]/, "")
      |> String.slice(0, 14)

    "correction_#{timestamp}_#{System.unique_integer([:positive])}"
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
