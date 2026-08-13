defmodule SymphonyElixir.ExtensionsAudit.Git do
  @moduledoc false

  @git_env [
    {"GIT_NO_LAZY_FETCH", "1"},
    {"GIT_OPTIONAL_LOCKS", "0"},
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_SYSTEM", "/dev/null"},
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_CONFIG_COUNT", "0"},
    {"GIT_CONFIG_PARAMETERS", nil},
    {"GIT_NO_REPLACE_OBJECTS", "1"},
    {"GIT_REPLACE_REF_BASE", nil},
    {"GIT_SHALLOW_FILE", nil},
    {"GIT_TRACE", nil},
    {"GIT_TRACE_CURL", nil},
    {"GIT_CURL_VERBOSE", nil},
    {"GIT_TRACE_FSMONITOR", nil},
    {"GIT_TRACE_PACK_ACCESS", nil},
    {"GIT_TRACE_PACKET", nil},
    {"GIT_TRACE_PERFORMANCE", nil},
    {"GIT_TRACE_REFS", nil},
    {"GIT_TRACE_SETUP", nil},
    {"GIT_TRACE_SHALLOW", nil},
    {"GIT_TRACE2", nil},
    {"GIT_TRACE2_EVENT", nil},
    {"GIT_TRACE2_PERF", nil},
    {"GIT_DIR", nil},
    {"GIT_WORK_TREE", nil},
    {"GIT_COMMON_DIR", nil},
    {"GIT_OBJECT_DIRECTORY", nil},
    {"GIT_ALTERNATE_OBJECT_DIRECTORIES", nil},
    {"GIT_INDEX_FILE", nil},
    {"GIT_NAMESPACE", nil},
    {"GIT_CEILING_DIRECTORIES", nil},
    {"GIT_DISCOVERY_ACROSS_FILESYSTEM", nil}
  ]

  @spec run((String.t(), [String.t()], keyword() -> {String.t(), integer()}), Path.t(), [String.t()]) ::
          {:ok, String.t(), integer()} | {:error, String.t()}
  def run(git, repo_root, args) when is_function(git, 3) do
    case git.("git", ["-C", repo_root | args], stderr_to_stdout: true, env: @git_env) do
      {output, status} when is_binary(output) and is_integer(status) -> {:ok, output, status}
    end
  rescue
    error in ErlangError ->
      if Map.get(error, :original) == :enoent do
        {:error, "git executable not found on PATH"}
      else
        reraise error, __STACKTRACE__
      end
  end
end
