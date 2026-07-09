defmodule SymphonyElixir.KnowledgeLedger do
  @moduledoc false

  @knowledge_dir ".orocsy/delivery/knowledge"
  @summary_max_length 800
  @symbol_max_length 80
  @max_symbols 20

  @spec knowledge_dir() :: String.t()
  def knowledge_dir, do: @knowledge_dir

  @spec append(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def append(workspace, attrs) when is_binary(workspace) and is_map(attrs) do
    with {:ok, entry} <- build_entry(workspace, attrs),
         {:ok, path} <- ledger_path(workspace, entry) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(entry) <> "\n", [:append])
      {:ok, entry}
    end
  rescue
    error -> {:error, {:knowledge_ledger_append_failed, Exception.message(error)}}
  end

  def append(_workspace, _attrs), do: {:error, :invalid_knowledge_entry}

  @spec load(String.t(), map()) :: map()
  def load(workspace, preflight_or_requirements) when is_binary(workspace) and is_map(preflight_or_requirements) do
    identifiers = ledger_identifiers(preflight_or_requirements)

    classifications =
      workspace
      |> ledger_files(identifiers)
      |> Enum.flat_map(&read_jsonl_file/1)
      |> Enum.map(&classify_entry(workspace, &1))
      |> Enum.reject(&is_nil/1)

    fresh = Enum.filter(classifications, &(&1["status"] == "fresh"))
    stale = Enum.filter(classifications, &(&1["status"] == "stale"))

    %{
      "schema_version" => 1,
      "fresh" => Enum.map(fresh, &summary_entry/1),
      "stale" => Enum.map(stale, &summary_entry/1),
      "read_context" => Enum.map(fresh ++ Enum.filter(stale, & &1["refresh_allowed"]), &read_context_entry/1)
    }
  rescue
    _error ->
      %{"schema_version" => 1, "fresh" => [], "stale" => [], "read_context" => []}
  end

  def load(_workspace, _preflight_or_requirements), do: %{"schema_version" => 1, "fresh" => [], "stale" => [], "read_context" => []}

  @spec blob_id(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def blob_id(workspace, relative_path) when is_binary(workspace) and is_binary(relative_path) do
    with {:ok, path} <- safe_relative_path(relative_path),
         true <- File.regular?(Path.join(workspace, path)),
         {output, 0} <- System.cmd("git", ["hash-object", "--", path], cd: workspace, stderr_to_stdout: true),
         blob when blob != "" <- String.trim(output) do
      {:ok, blob}
    else
      false -> {:error, {:file_missing, relative_path}}
      {output, status} -> {:error, {:git_hash_object_failed, status, String.trim(to_string(output))}}
      _ -> {:error, {:blob_unavailable, relative_path}}
    end
  rescue
    error -> {:error, {:blob_lookup_failed, Exception.message(error)}}
  end

  def blob_id(_workspace, _relative_path), do: {:error, :invalid_path}

  defp build_entry(workspace, attrs) do
    attrs = stringify_keys(attrs)

    with {:ok, path} <- safe_relative_path(attrs["path"]),
         {:ok, blob} <- blob_id(workspace, path),
         summary when summary != "" <- compact_summary(attrs["summary"]) do
      now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      entry =
        %{
          "schema_version" => 1,
          "issue" => compact_identifier(attrs["issue"]),
          "parent" => compact_identifier(attrs["parent"]),
          "path" => path,
          "git_blob" => blob,
          "summary" => summary,
          "relevant_symbols" => compact_symbols(attrs["relevant_symbols"]),
          "operation" => "read",
          "source_event" => attrs["source_event"] || "scope.access.decided",
          "valid_until" => "file_changes",
          "created_at" => attrs["created_at"] || now,
          "scope" => ledger_scope(attrs)
        }
        |> Enum.reject(fn {_key, value} -> blank?(value) end)
        |> Map.new()

      {:ok, entry}
    else
      "" -> {:error, :missing_summary}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_knowledge_entry}
    end
  end

  defp ledger_path(workspace, %{"scope" => "parent", "parent" => parent}) when is_binary(parent) and parent != "" do
    {:ok, Path.join([shared_workspace_root(workspace), @knowledge_dir, "parent-#{safe_identifier(parent)}.jsonl"])}
  end

  defp ledger_path(workspace, %{"issue" => issue}) when is_binary(issue) and issue != "" do
    {:ok, Path.join([workspace, @knowledge_dir, "issue-#{safe_identifier(issue)}.jsonl"])}
  end

  defp ledger_path(workspace, %{"parent" => parent}) when is_binary(parent) and parent != "" do
    {:ok, Path.join([shared_workspace_root(workspace), @knowledge_dir, "parent-#{safe_identifier(parent)}.jsonl"])}
  end

  defp ledger_path(_workspace, _entry), do: {:error, :missing_issue_or_parent}

  defp ledger_scope(%{"scope" => scope}) when scope in ["issue", "parent"], do: scope
  defp ledger_scope(%{"promotion" => "parent"}), do: "parent"

  defp ledger_scope(%{"parent" => parent} = attrs) when is_binary(parent) and parent != "" do
    if compact_identifier(attrs["issue"]), do: "issue", else: "parent"
  end

  defp ledger_scope(_attrs), do: "issue"

  defp ledger_identifiers(%{"requirements" => requirements} = preflight) when is_map(requirements) do
    %{
      issue: compact_identifier(requirements["identifier"] || preflight["issue"]),
      parent: compact_identifier(requirements["feature_group"] || requirements["parent"])
    }
  end

  defp ledger_identifiers(%{} = requirements) do
    %{
      issue: compact_identifier(requirements["identifier"] || requirements["issue"]),
      parent: compact_identifier(requirements["feature_group"] || requirements["parent"])
    }
  end

  defp ledger_files(workspace, %{issue: issue, parent: parent}) do
    [
      ledger_file_for(workspace, "issue", issue),
      ledger_file_for(workspace, "parent", parent),
      shared_ledger_file_for(workspace, "parent", parent)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
  end

  defp ledger_file_for(_workspace, _scope, identifier) when identifier in [nil, ""], do: nil
  defp ledger_file_for(workspace, scope, identifier), do: Path.join([workspace, @knowledge_dir, "#{scope}-#{safe_identifier(identifier)}.jsonl"])

  defp shared_ledger_file_for(_workspace, _scope, identifier) when identifier in [nil, ""], do: nil

  defp shared_ledger_file_for(workspace, scope, identifier) do
    Path.join([shared_workspace_root(workspace), @knowledge_dir, "#{scope}-#{safe_identifier(identifier)}.jsonl"])
  end

  defp shared_workspace_root(workspace) when is_binary(workspace), do: Path.dirname(workspace)
  defp shared_workspace_root(_workspace), do: "."

  defp read_jsonl_file(path) do
    path
    |> File.stream!()
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{} = entry} -> [entry]
        _ -> []
      end
    end)
  rescue
    _error -> []
  end

  defp classify_entry(workspace, entry) when is_map(entry) do
    entry = stringify_keys(entry)

    with path when is_binary(path) <- entry["path"],
         {:ok, normalized_path} <- safe_relative_path(path),
         stored_blob when is_binary(stored_blob) and stored_blob != "" <- entry["git_blob"] do
      case blob_id(workspace, normalized_path) do
        {:ok, ^stored_blob} ->
          entry
          |> Map.put("path", normalized_path)
          |> Map.put("status", "fresh")
          |> Map.put("refresh_allowed", false)

        {:ok, current_blob} ->
          entry
          |> Map.put("path", normalized_path)
          |> Map.put("status", "stale")
          |> Map.put("current_git_blob", current_blob)
          |> Map.put("refresh_allowed", true)

        _ ->
          entry
          |> Map.put("path", normalized_path)
          |> Map.put("status", "stale")
          |> Map.put("refresh_allowed", false)
      end
    else
      _ -> nil
    end
  end

  defp classify_entry(_workspace, _entry), do: nil

  defp read_context_entry(%{"status" => "fresh"} = entry) do
    %{
      "path" => entry["path"],
      "source" => knowledge_source(entry),
      "operation" => "read",
      "expires" => "file_changes",
      "reason" => "Common knowledge ledger has an unchanged blob for this path.",
      "summary" => entry["summary"],
      "relevant_symbols" => entry["relevant_symbols"] || [],
      "git_blob" => entry["git_blob"]
    }
  end

  defp read_context_entry(%{"status" => "stale"} = entry) do
    %{
      "path" => entry["path"],
      "source" => "knowledge_ledger.stale_refresh",
      "operation" => "read",
      "expires" => "turn",
      "reason" => "Common knowledge ledger entry is stale; allow one bounded refresh.",
      "summary" => entry["summary"],
      "relevant_symbols" => entry["relevant_symbols"] || [],
      "git_blob" => entry["current_git_blob"],
      "stale_git_blob" => entry["git_blob"]
    }
  end

  defp summary_entry(entry) do
    entry
    |> Map.take([
      "issue",
      "parent",
      "path",
      "git_blob",
      "current_git_blob",
      "summary",
      "relevant_symbols",
      "operation",
      "source_event",
      "valid_until",
      "created_at",
      "scope",
      "status",
      "refresh_allowed"
    ])
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp knowledge_source(%{"scope" => "parent"}), do: "knowledge_ledger.parent"
  defp knowledge_source(_entry), do: "knowledge_ledger.issue"

  defp safe_relative_path(path) when is_binary(path) do
    normalized =
      path
      |> String.trim()
      |> String.trim_leading("./")
      |> String.trim_trailing(".")
      |> String.trim_trailing(",")

    segments = Path.split(normalized)

    cond do
      normalized == "" ->
        {:error, :blank_path}

      Path.type(normalized) == :absolute ->
        {:error, {:absolute_path, path}}

      ".." in segments ->
        {:error, {:path_traversal, path}}

      String.starts_with?(normalized, ".orocsy/") ->
        {:error, {:runtime_path, path}}

      true ->
        {:ok, normalized}
    end
  end

  defp safe_relative_path(_path), do: {:error, :invalid_path}

  defp compact_summary(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, @summary_max_length)
  end

  defp compact_summary(_value), do: ""

  defp compact_symbols(values) when is_list(values) do
    values
    |> Enum.flat_map(fn
      value when is_binary(value) ->
        value = value |> String.trim() |> String.slice(0, @symbol_max_length)
        if value == "", do: [], else: [value]

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Enum.take(@max_symbols)
  end

  defp compact_symbols(_values), do: []

  defp compact_identifier(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      identifier -> identifier
    end
  end

  defp compact_identifier(_value), do: nil

  defp safe_identifier(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp blank?(value), do: value in [nil, "", []]
end
