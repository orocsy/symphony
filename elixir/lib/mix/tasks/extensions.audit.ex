defmodule Mix.Tasks.Extensions.Audit do
  @moduledoc """
  Verifies the repository's pinned OpenAI baseline and kernel patch budget.

      mix extensions.audit [--only baseline|budget] [--repo-root PATH]

  The audit is local and read-only. Missing Git history fails closed; fetch the
  required objects outside this task and retry.
  """

  use Mix.Task

  alias SymphonyElixir.ExtensionsAudit
  alias SymphonyElixir.ExtensionsAudit.{BudgetReport, Finding, Report}

  @shortdoc "Verifies the upstream baseline and kernel patch budget"
  @switches [only: :string, repo_root: :string]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)
    validate_args!(opts, argv, invalid)

    root = repo_root(opts)

    case Keyword.get(opts, :only) do
      "baseline" -> run_check(:baseline, root)
      "budget" -> run_check(:budget, root)
      nil -> run_all(root)
    end
  end

  defp run_all(root) do
    case run_check(:baseline, root) do
      :ok -> run_check(:budget, root)
    end
  end

  defp run_check(check, root) do
    result =
      case check do
        :baseline -> ExtensionsAudit.verify_baseline(root)
        :budget -> ExtensionsAudit.verify_budget(root)
      end

    case result do
      {:ok, report} ->
        Mix.shell().info(format_success(report))
        :ok

      {:error, findings} ->
        Enum.each(findings, &Mix.shell().error(format_finding(check, &1)))
        Mix.raise("extensions.audit #{check} failed")
    end
  end

  defp validate_args!(opts, [], []) do
    case Keyword.get(opts, :only) do
      nil -> :ok
      "baseline" -> :ok
      "budget" -> :ok
      value -> Mix.raise("extensions.audit --only accepts baseline or budget, got: #{inspect(value)}")
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

  defp format_success(%BudgetReport{} = report) do
    "extensions.audit budget: ok baseline=#{report.baseline_commit} head=#{report.head} changed_kernel_files=#{length(report.changed_kernel_files)} changed_lines=#{report.changed_lines} max_changed_lines=#{report.maximum_changed_lines}"
  end

  defp format_finding(check, %Finding{} = finding) do
    values =
      [field: finding.field, expected: finding.expected, actual: finding.actual, detail: finding.detail]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{inspect(value)}" end)

    String.trim("extensions.audit #{check}: error code=#{finding.code} #{values}")
  end
end
