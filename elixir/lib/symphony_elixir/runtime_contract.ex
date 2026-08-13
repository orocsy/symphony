defmodule SymphonyElixir.RuntimeContract do
  @moduledoc """
  Compiles the machine-readable Runtime Contract embedded in a Linear issue.

  Markdown outside the fenced contract remains worker context and never gains
  authority over branch, scope, MIU, validation, or review decisions.
  """

  @schema_version 1
  @default_validation_timeout_ms 900_000
  @max_validation_timeout_ms 1_800_000
  @allowed_ticket_types ~w(implementation test-spec integration-check contract design)
  @allowed_review_authorities ~w(github_codex)
  @allowed_merge_methods ~w(squash merge rebase)

  @type compiled :: %{
          contract: map(),
          contract_hash: String.t(),
          write_scope: [String.t()],
          read_context: [String.t()],
          denied_scope: [String.t()],
          validations: [String.t()],
          miu_ids: [String.t()]
        }

  @spec compile(String.t() | nil) :: {:ok, compiled()} | {:error, [String.t()]} | :none
  def compile(description) when is_binary(description) do
    case runtime_contract_yaml(description) do
      nil ->
        :none

      yaml ->
        with {:ok, decoded} <- decode_yaml(yaml),
             {:ok, contract} <- validate(decoded) do
          {:ok, compiled(contract)}
        end
    end
  end

  def compile(_description), do: :none

  @spec issue_revision(String.t() | nil, term()) :: String.t()
  def issue_revision(description, _updated_at) do
    "sha256:" <> sha256(description || "")
  end

  @spec contract_hash(map()) :: String.t()
  def contract_hash(contract) when is_map(contract) do
    "sha256:" <> sha256(canonical_json(contract))
  end

  defp runtime_contract_yaml(description) do
    section_pattern = ~r/^##\s+Runtime Contract\s*\n(.*?)(?=^##\s+|\z)/ms

    with [section] <- Regex.run(section_pattern, description, capture: :all_but_first),
         [yaml] <- Regex.run(~r/```ya?ml\s*\n(.*?)```/s, section, capture: :all_but_first) do
      String.trim(yaml)
    else
      _ -> nil
    end
  end

  defp decode_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, decoded} when is_map(decoded) -> {:ok, stringify_keys(decoded)}
      {:ok, _decoded} -> {:error, ["runtime_contract_not_a_map"]}
      {:error, reason} -> {:error, ["runtime_contract_yaml_error:#{inspect(reason)}"]}
    end
  end

  defp validate(contract) do
    errors =
      []
      |> validate_schema_version(contract)
      |> validate_ticket_type(contract)
      |> validate_branch(contract, "base_branch")
      |> validate_branch(contract, "integration_branch")
      |> validate_certification_base_sha(contract)
      |> validate_string_list(contract, "dependencies")
      |> validate_optional_contract_scope(contract, "denied_scope")
      |> validate_mius(contract)
      |> validate_scope_conflicts(contract)
      |> validate_validation_list(contract, "final_validations")
      |> validate_validation_timeout(contract)
      |> validate_review(contract)
      |> validate_merge(contract)

    case Enum.uniq(errors) do
      [] -> {:ok, normalize_contract(contract)}
      errors -> {:error, errors}
    end
  end

  defp validate_schema_version(errors, %{"schema_version" => @schema_version}), do: errors

  defp validate_schema_version(errors, contract) do
    ["unsupported_schema_version:#{inspect(contract["schema_version"])}" | errors]
  end

  defp validate_ticket_type(errors, %{"ticket_type" => ticket_type}) when ticket_type in @allowed_ticket_types,
    do: errors

  defp validate_ticket_type(errors, contract),
    do: ["invalid_ticket_type:#{inspect(contract["ticket_type"])}" | errors]

  defp validate_branch(errors, contract, key) do
    value = contract[key]

    if valid_branch?(value) do
      errors
    else
      ["invalid_#{key}:#{inspect(value)}" | errors]
    end
  end

  defp validate_certification_base_sha(errors, contract) do
    case Map.get(contract, "certification_base_sha") do
      nil ->
        errors

      sha when is_binary(sha) ->
        if Regex.match?(~r/\A[0-9a-fA-F]{40,64}\z/, sha),
          do: errors,
          else: ["invalid_certification_base_sha" | errors]

      _ ->
        ["invalid_certification_base_sha" | errors]
    end
  end

  defp validate_string_list(errors, contract, key) do
    case contract[key] do
      values when is_list(values) ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
          errors
        else
          ["invalid_#{key}" | errors]
        end

      _ ->
        ["invalid_#{key}" | errors]
    end
  end

  defp validate_optional_contract_scope(errors, contract, key) do
    case Map.get(contract, key, []) do
      paths when is_list(paths) ->
        Enum.reduce(paths, errors, fn path, acc ->
          if valid_scope_path?(path), do: acc, else: ["invalid_#{key}:#{error_value(path)}" | acc]
        end)

      _ ->
        ["invalid_#{key}" | errors]
    end
  end

  defp validate_mius(errors, %{"mius" => mius}) when is_list(mius) and mius != [] do
    normalized = Enum.map(mius, &stringify_keys/1)
    miu_ids = Enum.map(normalized, fn miu -> if is_map(miu), do: Map.get(miu, "id") end)

    errors =
      miu_ids
      |> Enum.reject(&(is_binary(&1) and String.trim(&1) != ""))
      |> case do
        [] -> errors
        _ -> ["invalid_miu_id" | errors]
      end

    errors =
      miu_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.frequencies()
      |> Enum.reduce(errors, fn
        {id, count}, acc when count > 1 -> ["duplicate_miu_id:#{id}" | acc]
        {_id, _count}, acc -> acc
      end)

    Enum.reduce(normalized, errors, &validate_miu/2)
  end

  defp validate_mius(errors, _contract), do: ["invalid_mius" | errors]

  defp validate_miu(miu, errors) when is_map(miu) do
    id = Map.get(miu, "id", "unknown")

    errors
    |> validate_scope_list(miu, "write_scope", id)
    |> validate_optional_scope_list(miu, "read_context", id)
    |> validate_validation_list(miu, "validations", id)
  end

  defp validate_miu(_miu, errors), do: ["invalid_miu" | errors]

  defp validate_scope_conflicts(errors, %{"mius" => mius} = contract) when is_list(mius) do
    denied_scope = Map.get(contract, "denied_scope", [])
    Enum.reduce(mius, errors, &validate_miu_scope_conflicts(&1, &2, denied_scope))
  end

  defp validate_scope_conflicts(errors, _contract), do: errors

  defp validate_miu_scope_conflicts(raw_miu, errors, denied_scope) do
    case stringify_keys(raw_miu) do
      %{} = miu ->
        miu_id = Map.get(miu, "id", "unknown")

        errors
        |> validate_authorized_scope_not_fully_denied(
          Map.get(miu, "write_scope", []),
          denied_scope,
          "write_scope",
          miu_id
        )
        |> validate_authorized_scope_not_fully_denied(
          Map.get(miu, "read_context", []),
          denied_scope,
          "read_context",
          miu_id
        )

      _malformed_miu ->
        errors
    end
  end

  defp validate_authorized_scope_not_fully_denied(
         errors,
         authorized_scope,
         denied_scope,
         scope_kind,
         miu_id
       )
       when is_list(authorized_scope) and is_list(denied_scope) do
    Enum.reduce(authorized_scope, errors, fn path, acc ->
      if is_binary(path) and Enum.any?(denied_scope, &scope_fully_covers?(&1, path)) do
        ["#{scope_kind}_denied:#{error_value(miu_id)}:#{error_value(path)}" | acc]
      else
        acc
      end
    end)
  end

  defp validate_authorized_scope_not_fully_denied(
         errors,
         _authorized_scope,
         _denied_scope,
         _scope_kind,
         _miu_id
       ),
       do: errors

  defp scope_fully_covers?(denied_pattern, authorized_pattern)
       when is_binary(denied_pattern) and is_binary(authorized_pattern) do
    cond do
      denied_pattern == authorized_pattern ->
        true

      String.ends_with?(denied_pattern, "/**") ->
        scope_has_prefix?(authorized_pattern, String.trim_trailing(denied_pattern, "/**"))

      String.ends_with?(denied_pattern, "/*") ->
        scope_has_prefix?(authorized_pattern, String.trim_trailing(denied_pattern, "/*"))

      String.contains?(denied_pattern, "*") ->
        wildcard_scope_matches?(authorized_pattern, denied_pattern)

      true ->
        scope_has_prefix?(authorized_pattern, denied_pattern)
    end
  end

  defp scope_fully_covers?(_denied_pattern, _authorized_pattern), do: false

  defp scope_has_prefix?(path, prefix) do
    path == prefix or String.starts_with?(path, prefix <> "/")
  end

  defp wildcard_scope_matches?(path, scope) do
    scope
    |> Regex.escape()
    |> String.replace("\\*", ".*")
    |> then(&Regex.compile!("^#{&1}$"))
    |> Regex.match?(path)
  end

  defp validate_scope_list(errors, map, key, id) do
    case map[key] do
      paths when is_list(paths) and paths != [] ->
        Enum.reduce(paths, errors, fn path, acc ->
          if valid_scope_path?(path),
            do: acc,
            else: ["invalid_#{key}:#{error_value(id)}:#{error_value(path)}" | acc]
        end)

      _ ->
        ["invalid_#{key}:#{error_value(id)}" | errors]
    end
  end

  defp validate_optional_scope_list(errors, map, key, id) do
    case Map.get(map, key, []) do
      paths when is_list(paths) ->
        Enum.reduce(paths, errors, fn path, acc ->
          if valid_scope_path?(path),
            do: acc,
            else: ["invalid_#{key}:#{error_value(id)}:#{error_value(path)}" | acc]
        end)

      _ ->
        ["invalid_#{key}:#{error_value(id)}" | errors]
    end
  end

  defp validate_validation_list(errors, map, key, id \\ nil) do
    case map[key] do
      commands when is_list(commands) and commands != [] ->
        Enum.reduce(commands, errors, fn command, acc ->
          if valid_validation_command?(command) do
            acc
          else
            [validation_error(key, id, command) | acc]
          end
        end)

      _ ->
        [validation_error(key, id, nil) | errors]
    end
  end

  defp validation_error(key, nil, value), do: "invalid_#{key}:#{inspect(value)}"
  defp validation_error(key, id, value), do: "invalid_#{key}:#{error_value(id)}:#{inspect(value)}"

  defp error_value(value) when is_binary(value), do: value
  defp error_value(value), do: inspect(value)

  defp validate_review(errors, %{"review" => review}) when is_map(review) do
    review = stringify_keys(review)
    authority = review["authority"]
    current_head? = review["require_current_head"]

    errors = if authority in @allowed_review_authorities, do: errors, else: ["invalid_review_authority" | errors]
    if current_head? == true, do: errors, else: ["review_must_require_current_head" | errors]
  end

  defp validate_review(errors, _contract), do: ["invalid_review" | errors]

  defp validate_merge(errors, contract) do
    merge = contract |> Map.get("merge", %{}) |> stringify_keys()

    cond do
      not is_map(merge) ->
        ["invalid_merge" | errors]

      Map.get(merge, "automatic", false) not in [true, false] ->
        ["invalid_merge_automatic" | errors]

      Map.get(merge, "automatic", false) == true and review_authority(contract) != "github_codex" ->
        ["automatic_merge_requires_github_codex_review" | errors]

      Map.get(merge, "method", "squash") not in @allowed_merge_methods ->
        ["invalid_merge_method" | errors]

      Map.get(merge, "require_ci_checks", true) not in [true, false] ->
        ["invalid_merge_require_ci_checks" | errors]

      not valid_completed_state?(Map.get(merge, "completed_state", "Done")) ->
        ["invalid_merge_completed_state" | errors]

      true ->
        errors
    end
  end

  defp review_authority(%{"review" => review}) when is_map(review), do: stringify_keys(review)["authority"]
  defp review_authority(_contract), do: nil

  defp validate_validation_timeout(errors, contract) do
    case Map.get(contract, "validation_timeout_ms", @default_validation_timeout_ms) do
      timeout when is_integer(timeout) and timeout >= 1_000 and timeout <= @max_validation_timeout_ms ->
        errors

      timeout ->
        ["invalid_validation_timeout_ms:#{inspect(timeout)}" | errors]
    end
  end

  defp compiled(contract) do
    mius = contract["mius"]

    %{
      contract: contract,
      contract_hash: contract_hash(contract),
      write_scope: mius |> Enum.flat_map(& &1["write_scope"]) |> Enum.uniq(),
      read_context: mius |> Enum.flat_map(&Map.get(&1, "read_context", [])) |> Enum.uniq(),
      denied_scope: contract |> Map.get("denied_scope", []) |> Enum.uniq(),
      validations:
        (Enum.flat_map(mius, & &1["validations"]) ++ contract["final_validations"])
        |> Enum.uniq(),
      miu_ids: Enum.map(mius, & &1["id"])
    }
  end

  defp normalize_contract(contract) do
    contract
    |> Map.put("dependencies", Enum.map(contract["dependencies"], &String.trim/1))
    |> Map.put("mius", Enum.map(contract["mius"], &normalize_miu/1))
    |> Map.put("final_validations", Enum.map(contract["final_validations"], &String.trim/1))
    |> Map.put_new("validation_timeout_ms", @default_validation_timeout_ms)
    |> normalize_certification_base_sha()
    |> Map.put("review", stringify_keys(contract["review"]))
    |> Map.put("merge", normalize_merge(Map.get(contract, "merge", %{})))
    |> Map.put_new("denied_scope", [])
  end

  defp normalize_certification_base_sha(%{"certification_base_sha" => sha} = contract)
       when is_binary(sha),
       do: Map.put(contract, "certification_base_sha", String.downcase(sha))

  defp normalize_certification_base_sha(contract), do: contract

  defp normalize_merge(merge) do
    merge
    |> stringify_keys()
    |> Map.put_new("automatic", false)
    |> Map.put_new("method", "squash")
    |> Map.put_new("require_ci_checks", true)
    |> Map.put_new("completed_state", "Done")
  end

  defp normalize_miu(miu) do
    miu
    |> stringify_keys()
    |> Map.update!("id", &String.trim/1)
    |> Map.update!("write_scope", &Enum.map(&1, fn path -> String.trim(path) end))
    |> Map.update!("validations", &Enum.map(&1, fn command -> String.trim(command) end))
    |> Map.update("read_context", [], &Enum.map(&1, fn path -> String.trim(path) end))
  end

  defp valid_scope_path?(path) when is_binary(path) do
    trimmed = String.trim(path)
    segments = String.split(trimmed, "/", trim: false)

    trimmed == path and
      trimmed != "" and
      not String.starts_with?(trimmed, ["/", "~"]) and
      ".." not in segments and
      Enum.all?(segments, &Regex.match?(~r/^[A-Za-z0-9._*()\[\]@+-]+$/, &1))
  end

  defp valid_scope_path?(_path), do: false

  defp valid_branch?(branch) when is_binary(branch) do
    branch != "" and
      not String.contains?(branch, [" ", "..", "~", "^", ":", "?", "*", "["]) and
      Regex.match?(~r/^[A-Za-z0-9._\/-]+$/, branch)
  end

  defp valid_branch?(_branch), do: false

  defp valid_completed_state?(state) when is_binary(state) do
    state = String.trim(state)
    state != "" and byte_size(state) <= 80 and not String.contains?(state, ["\n", "\r"])
  end

  defp valid_completed_state?(_state), do: false

  defp valid_validation_command?(command) when is_binary(command) do
    trimmed = String.trim(command)

    trimmed == command and
      trimmed != "" and
      not String.contains?(trimmed, ["\n", "&&", "||", "|", ";", "`", "$(", ">", "<"]) and
      validation_executable?(trimmed) and
      not shell_command_mode?(trimmed)
  end

  defp valid_validation_command?(_command), do: false

  defp validation_executable?(command) do
    command
    |> OptionParser.split()
    |> Enum.drop_while(&Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=.*/, &1))
    |> Kernel.!=([])
  end

  defp shell_command_mode?(command) do
    command
    |> OptionParser.split()
    |> Enum.with_index()
    |> Enum.any?(fn {part, index} ->
      executable = part |> Path.basename() |> String.downcase()
      remaining = command |> OptionParser.split() |> Enum.drop(index + 1)

      cond do
        executable in ~w(sh bash zsh dash ksh fish) -> Enum.any?(remaining, &shell_command_flag?/1)
        executable in ~w(powershell powershell.exe pwsh pwsh.exe) -> Enum.any?(remaining, &powershell_command_flag?/1)
        executable in ~w(cmd cmd.exe) -> Enum.any?(remaining, &(String.downcase(&1) in ["/c", "/k"]))
        executable in ~w(env env.exe) -> Enum.any?(remaining, &(String.downcase(&1) in ["-s", "--split-string"]))
        true -> false
      end
    end)
  rescue
    _error -> true
  end

  defp shell_command_flag?(flag), do: Regex.match?(~r/^-[^-]*c/, String.downcase(flag))

  defp powershell_command_flag?(flag),
    do: String.downcase(flag) in ["-c", "-command", "-e", "-ec", "-encodedcommand"]

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join(",", fn {key, nested} -> Jason.encode!(to_string(key)) <> ":" <> canonical_json(nested) end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp canonical_json(value) when is_list(value), do: "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"
  defp canonical_json(value), do: Jason.encode!(value)

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end
end
