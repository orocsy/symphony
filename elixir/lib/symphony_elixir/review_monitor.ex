defmodule SymphonyElixir.ReviewMonitor do
  @moduledoc """
  Bridges current PR review feedback back into the tracker rework lane.
  """

  require Logger

  alias SymphonyElixir.{Config, Tracker}
  alias SymphonyElixir.Linear.Issue

  @review_feedback_states MapSet.new(["CHANGES_REQUESTED", "REQUEST_CHANGES"])

  @spec run_once() :: :ok
  def run_once do
    settings = Config.settings!()
    monitor = settings.review_monitor

    if monitor.enabled do
      scan_review_states(monitor)
    end

    :ok
  rescue
    error ->
      Logger.warning("Review monitor failed unexpectedly: #{Exception.message(error)}")
      :ok
  end

  defp scan_review_states(monitor) do
    case Tracker.fetch_issues_by_states(monitor.states) do
      {:ok, issues} ->
        Enum.each(issues, &maybe_mark_issue_for_rework(&1, monitor))

      {:error, reason} ->
        Logger.warning("Review monitor could not fetch review-state issues: #{inspect(reason)}")
    end
  end

  defp maybe_mark_issue_for_rework(%Issue{} = issue, monitor) do
    case feedback_for_issue(issue, monitor) do
      {:ok, nil} ->
        :ok

      {:ok, feedback} ->
        mark_rework(issue, monitor, feedback)

      {:error, reason} ->
        Logger.warning("Review monitor could not inspect #{issue_context(issue)}: #{inspect(reason)}")
    end
  end

  defp maybe_mark_issue_for_rework(_issue, _monitor), do: :ok

  defp feedback_for_issue(%Issue{branch_name: branch}, monitor)
       when is_binary(branch) and branch != "" do
    with {:ok, repo} <- normalize_repo(monitor.repo),
         {:ok, pr} <- fetch_open_pull_request(repo, branch),
         {:ok, comments} <- fetch_pull_comments(repo, pr),
         {:ok, reviews} <- fetch_pull_reviews(repo, pr) do
      current_feedback =
        current_head_comments(pr, comments) ++ current_head_reviews(pr, reviews)

      case current_feedback do
        [] -> {:ok, nil}
        feedback -> {:ok, build_feedback(repo, pr, feedback)}
      end
    end
  end

  defp feedback_for_issue(%Issue{} = issue, _monitor) do
    Logger.debug("Review monitor skipped #{issue_context(issue)} because it has no branch name")
    {:ok, nil}
  end

  defp normalize_repo(repo) when is_binary(repo) do
    repo =
      repo
      |> String.trim()
      |> String.replace_prefix("https://github.com/", "")
      |> String.replace_prefix("git@github.com:", "")
      |> String.replace_suffix(".git", "")

    if String.match?(repo, ~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/) do
      {:ok, repo}
    else
      {:error, {:invalid_github_repo, repo}}
    end
  end

  defp normalize_repo(repo), do: {:error, {:invalid_github_repo, repo}}

  defp fetch_open_pull_request(repo, branch) do
    owner = repo |> String.split("/", parts: 2) |> hd()

    case github_api("repos/#{repo}/pulls?#{URI.encode_query(%{head: "#{owner}:#{branch}", state: "open"})}") do
      {:ok, [pr | _]} when is_map(pr) ->
        {:ok, pr}

      {:ok, []} ->
        fetch_open_pull_request_by_branch(repo, branch)

      {:ok, payload} ->
        {:error, {:unexpected_pull_search_payload, payload}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_open_pull_request_by_branch(repo, branch) do
    case github_api("repos/#{repo}/pulls?#{URI.encode_query(%{state: "open", per_page: 100})}") do
      {:ok, pulls} when is_list(pulls) ->
        case Enum.find(pulls, &(get_in(&1, ["head", "ref"]) == branch)) do
          nil -> {:ok, nil}
          pr -> {:ok, pr}
        end

      {:ok, payload} ->
        {:error, {:unexpected_pull_list_payload, payload}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_pull_comments(_repo, nil), do: {:ok, []}

  defp fetch_pull_comments(repo, pr) do
    case pr_number(pr) do
      nil -> {:ok, []}
      number -> github_api("repos/#{repo}/pulls/#{number}/comments")
    end
  end

  defp fetch_pull_reviews(_repo, nil), do: {:ok, []}

  defp fetch_pull_reviews(repo, pr) do
    case pr_number(pr) do
      nil -> {:ok, []}
      number -> github_api("repos/#{repo}/pulls/#{number}/reviews")
    end
  end

  defp current_head_comments(nil, _comments), do: []

  defp current_head_comments(pr, comments) when is_list(comments) do
    head_sha = head_sha(pr)

    comments
    |> Enum.filter(&(is_current_head_comment?(&1, head_sha) and actionable_comment?(&1)))
    |> Enum.map(&%{type: :comment, payload: &1})
  end

  defp current_head_comments(_pr, _comments), do: []

  defp current_head_reviews(nil, _reviews), do: []

  defp current_head_reviews(pr, reviews) when is_list(reviews) do
    head_sha = head_sha(pr)

    reviews
    |> Enum.filter(&(is_current_head_review?(&1, head_sha) and feedback_review?(&1)))
    |> Enum.map(&%{type: :review, payload: &1})
  end

  defp current_head_reviews(_pr, _reviews), do: []

  defp is_current_head_comment?(comment, head_sha) when is_map(comment) and is_binary(head_sha) do
    comment["commit_id"] == head_sha
  end

  defp is_current_head_comment?(_comment, _head_sha), do: false

  defp actionable_comment?(comment) when is_map(comment) do
    comment
    |> Map.get("body", "")
    |> String.trim()
    |> then(&(&1 != ""))
  end

  defp actionable_comment?(_comment), do: false

  defp is_current_head_review?(review, head_sha) when is_map(review) and is_binary(head_sha) do
    review["commit_id"] == head_sha
  end

  defp is_current_head_review?(_review, _head_sha), do: false

  defp feedback_review?(review) when is_map(review) do
    state =
      review
      |> Map.get("state", "")
      |> String.upcase()

    MapSet.member?(@review_feedback_states, state)
  end

  defp feedback_review?(_review), do: false

  defp build_feedback(repo, pr, feedback) do
    %{
      repo: repo,
      pr_number: pr_number(pr),
      pr_url: pr["html_url"],
      head_sha: head_sha(pr),
      feedback: feedback
    }
  end

  defp mark_rework(%Issue{} = issue, monitor, feedback) do
    comment = feedback_comment(issue, monitor, feedback)

    case Tracker.update_issue_state(issue.id, monitor.rework_state) do
      :ok ->
        _ = Tracker.create_comment(issue.id, comment)
        Logger.info("Review monitor moved #{issue_context(issue)} to #{monitor.rework_state} for PR ##{feedback.pr_number}")

      {:error, reason} ->
        Logger.warning("Review monitor could not move #{issue_context(issue)} to #{monitor.rework_state}: #{inspect(reason)}")
    end
  end

  defp feedback_comment(%Issue{} = issue, monitor, feedback) do
    items =
      feedback.feedback
      |> Enum.take(5)
      |> Enum.map_join("\n", &("- " <> feedback_item_summary(&1)))

    more =
      case length(feedback.feedback) - 5 do
        count when count > 0 -> "\n- ...and #{count} more current-head review item(s)."
        _ -> ""
      end

    """
    Symphony review monitor detected current PR feedback and moved this issue to `#{monitor.rework_state}` so the Rework lane can run the review hardening loop.

    - Issue: `#{issue.identifier}`
    - PR: ##{feedback.pr_number} #{feedback.pr_url}
    - Reviewed head: `#{short_sha(feedback.head_sha)}`
    - Next action: Symphony should fix accepted current-code findings on the existing PR branch, revalidate, push, request `@codex review` again, and return to Human Review only after a fresh review scan is clean.

    Active feedback:
    #{items}#{more}
    """
    |> String.trim()
  end

  defp feedback_item_summary(%{type: :comment, payload: comment}) do
    location =
      [
        comment["path"],
        line_fragment(comment)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(":")

    [location, first_body_line(comment["body"]), comment["html_url"]]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" - ")
  end

  defp feedback_item_summary(%{type: :review, payload: review}) do
    ["Review #{review["state"]}", first_body_line(review["body"]), review["html_url"]]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" - ")
  end

  defp feedback_item_summary(_item), do: "Review feedback"

  defp first_body_line(body) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> List.first()
    |> to_string()
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/!\[[^\]]*\]\([^)]+\)/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(160)
  end

  defp first_body_line(_body), do: nil

  defp line_fragment(comment) do
    cond do
      is_integer(comment["line"]) -> to_string(comment["line"])
      is_integer(comment["original_line"]) -> to_string(comment["original_line"])
      true -> nil
    end
  end

  defp github_api(endpoint) do
    case github_api_runner().(endpoint) do
      {:ok, decoded} ->
        {:ok, decoded}

      {output, 0} when is_binary(output) ->
        Jason.decode(output)

      {output, exit_code} ->
        {:error, {:github_api_failed, exit_code, summarize_output(output)}}

      other ->
        {:error, {:github_api_unexpected_result, other}}
    end
  rescue
    error -> {:error, {:github_api_exception, Exception.message(error)}}
  end

  defp github_api_runner do
    case Application.get_env(:symphony_elixir, :github_api_runner) do
      runner when is_function(runner, 1) ->
        runner

      _ ->
        fn endpoint -> System.cmd("gh", ["api", endpoint], stderr_to_stdout: true) end
    end
  end

  defp pr_number(pr) when is_map(pr) do
    case pr["number"] do
      number when is_integer(number) -> number
      number when is_binary(number) -> number
      _ -> nil
    end
  end

  defp pr_number(_pr), do: nil

  defp head_sha(pr) when is_map(pr), do: get_in(pr, ["head", "sha"])
  defp head_sha(_pr), do: nil

  defp issue_context(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_context(%Issue{id: id}) when is_binary(id), do: id
  defp issue_context(_issue), do: "unknown"

  defp short_sha(sha) when is_binary(sha) and byte_size(sha) >= 10, do: binary_part(sha, 0, 10)
  defp short_sha(sha) when is_binary(sha), do: sha
  defp short_sha(_sha), do: "unknown"

  defp summarize_output(output) when is_binary(output) do
    output
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(500)
  end

  defp summarize_output(output), do: inspect(output, limit: 20, printable_limit: 500)

  defp truncate(value, max_bytes) when is_binary(value) and byte_size(value) > max_bytes do
    binary_part(value, 0, max_bytes) <> "..."
  end

  defp truncate(value, _max_bytes), do: value

  defp blank?(value), do: is_nil(value) or value == ""
end
