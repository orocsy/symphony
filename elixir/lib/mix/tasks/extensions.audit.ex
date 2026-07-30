defmodule Mix.Tasks.Extensions.Audit do
  @moduledoc false

  use Mix.Task

  alias SymphonyElixir.ExtensionsAudit
  alias SymphonyElixir.ExtensionsAudit.{Finding, Report}

  @shortdoc "Verifies the pinned upstream baseline and extension patch budget"
  @switches [only: :string, repo_root: :string]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)
    validate_args!(opts, argv, invalid)

    case ExtensionsAudit.verify_baseline(repo_root(opts)) do
      {:ok, report} ->
        Mix.shell().info(format_success(report))
        :ok

      {:error, findings} ->
        Enum.each(findings, &Mix.shell().error(format_finding(&1)))
        Mix.raise("extensions.audit baseline failed")
    end
  end

  defp validate_args!(opts, [], []) do
    case Keyword.get(opts, :only) do
      nil -> :ok
      "baseline" -> :ok
      value -> Mix.raise("extensions.audit --only accepts only baseline in OXE-0.1, got: #{inspect(value)}")
    end
  end

  defp validate_args!(_opts, argv, invalid) do
    Mix.raise("invalid extensions.audit arguments: #{inspect(argv ++ invalid)}")
  end

  defp repo_root(opts) do
    Keyword.get_lazy(opts, :repo_root, fn ->
      Mix.Project.project_file()
      |> Path.dirname()
      |> Path.dirname()
    end)
    |> Path.expand()
  end

  defp format_success(%Report{} = report) do
    "extensions.audit baseline: ok commit=#{report.baseline_commit} tree=#{report.repository_tree} elixir_tree=#{report.elixir_tree} first_parent=#{report.first_parent_verified}"
  end

  defp format_finding(%Finding{} = finding) do
    values =
      [field: finding.field, expected: finding.expected, actual: finding.actual, detail: finding.detail]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{inspect(value)}" end)

    String.trim("extensions.audit baseline: error code=#{finding.code} #{values}")
  end
end
