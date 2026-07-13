defmodule SymphonyElixir.ReviewMonitor do
  @moduledoc """
  Bridges current PR review feedback back into the tracker rework lane.
  """

  require Logger

  alias SymphonyElixir.{Config, Tracker}
  alias SymphonyElixir.Linear.Issue

  @review_feedback_states MapSet.new(["CHANGES_REQUESTED", "REQUEST_CHANGES"])
  @issue_comments_per_page 100
  @review_threads_query """
  query SymphonyPullReviewThreads($owner: String!, $name: String!, $number: Int!, $after: String) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        headRefOid
        reviewThreads(first: 100, after: $after) {
          nodes {
            isResolved
            isOutdated
            comments(first: 20) {
              nodes {
                author {
                  login
                }
                body
                path
                line
                originalLine
                createdAt
                outdated
                url
              }
            }
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
    }
  }
  """

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
    case Tracker.fetch_issues_by_states(review_scan_states(monitor)) do
      {:ok, issues} ->
        issues
        |> Enum.filter(&issue_allowed_by_tracker?/1)
        |> Enum.each(&maybe_mark_issue_for_rework(&1, monitor))

      {:error, reason} ->
        Logger.warning("Review monitor could not fetch review-state issues: #{inspect(reason)}")
    end
  end

  defp review_scan_states(monitor) do
    (monitor.states ++ Config.settings!().tracker.active_states)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp maybe_mark_issue_for_rework(%Issue{} = issue, monitor) do
    if issue.state == monitor.rework_state do
      :ok
    else
      case inspect_issue(issue, monitor) do
        {:ok, %{pr: nil}} ->
          :ok

        {:ok, %{feedback: []} = inspection} ->
          if merge_conflict_inspection?(inspection) do
            mark_rework(issue, monitor, build_merge_conflict_feedback(inspection))
          else
            maybe_advance_clean_codex_review(issue, monitor, inspection)
          end

        {:ok, %{repo: repo, pr: pr, feedback: feedback}} ->
          mark_rework(issue, monitor, build_feedback(repo, pr, feedback))

        {:error, reason} ->
          Logger.warning("Review monitor could not inspect #{issue_context(issue)}: #{inspect(reason)}")
      end
    end
  end

  defp maybe_mark_issue_for_rework(_issue, _monitor), do: :ok

  defp issue_allowed_by_tracker?(%Issue{} = issue) do
    allowlist =
      Config.settings!().tracker.issue_allowlist
      |> normalize_issue_allowlist()

    MapSet.size(allowlist) == 0 or
      MapSet.member?(allowlist, issue.id || "") or
      MapSet.member?(allowlist, issue.identifier || "")
  end

  defp issue_allowed_by_tracker?(_issue), do: false

  defp normalize_issue_allowlist(allowlist) when is_list(allowlist) do
    allowlist
    |> Enum.map(&(to_string(&1) |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalize_issue_allowlist(_allowlist), do: MapSet.new()

  @spec inspect_issue(Issue.t(), map()) :: {:ok, map()} | {:error, term()}
  def inspect_issue(%Issue{} = issue, monitor) do
    branches = issue_review_branch_candidates(issue)

    if branches == [] do
      Logger.debug("Review monitor skipped #{issue_context(issue)} because it has no branch name")

      {:ok,
       %{
         repo: nil,
         pr: nil,
         pr_number: nil,
         pr_url: nil,
         head_ref: nil,
         head_sha: nil,
         mergeable: nil,
         mergeable_state: nil,
         feedback: [],
         feedback_source: :none
       }}
    else
      with {:ok, repo} <- normalize_repo(monitor.repo) do
        inspect_issue_branches(repo, branches)
      end
    end
  end

  @spec current_feedback(String.t(), map() | nil) :: {:ok, list()} | {:error, term()}
  def current_feedback(repo, pr), do: current_feedback(repo, pr, [])

  @spec current_feedback(String.t(), map() | nil, keyword()) :: {:ok, list()} | {:error, term()}
  def current_feedback(repo, pr, opts) when is_binary(repo) and is_map(pr) and is_list(opts) do
    with {:ok, hydrated_pr} <- hydrate_pull_request_detail(repo, pr),
         {:ok, comments} <- fetch_pull_comments(repo, hydrated_pr),
         {:ok, reviews} <- fetch_pull_reviews(repo, hydrated_pr),
         {:ok, threads} <- fetch_pull_review_threads(repo, hydrated_pr),
         {:ok, check_feedback} <- maybe_fetch_current_check_feedback(repo, hydrated_pr, opts) do
      feedback =
        active_review_thread_feedback(threads) ++
          current_head_comments(hydrated_pr, comments) ++
          current_head_reviews(hydrated_pr, reviews)

      with {:ok, filtered_feedback, _source} <- feedback_not_cleared_by_codex_clean_review(repo, hydrated_pr, feedback, :current_feedback) do
        {:ok, filtered_feedback ++ check_feedback}
      end
    end
  end

  def current_feedback(_repo, nil, _opts), do: {:ok, []}
  def current_feedback(_repo, _pr, _opts), do: {:error, :invalid_pull_request}

  defp inspect_issue_branches(repo, branches) do
    branches
    |> Enum.reduce_while({:ok, no_pr_inspection(repo)}, fn branch, {:ok, fallback} ->
      case inspect_issue_branch(repo, branch) do
        {:ok, %{feedback: feedback} = inspection} when feedback != [] ->
          {:halt, {:ok, inspection}}

        {:ok, %{pr: pr} = inspection} when not is_nil(pr) ->
          next_fallback =
            case fallback do
              %{pr: nil} -> inspection
              _ -> fallback
            end

          {:cont, {:ok, next_fallback}}

        {:ok, _inspection} ->
          {:cont, {:ok, fallback}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp inspect_issue_branch(repo, branch) do
    with {:ok, pr} <- fetch_open_pull_request(repo, branch),
         {:ok, pr} <- hydrate_pull_request_detail(repo, pr),
         {:ok, comments} <- fetch_pull_comments(repo, pr),
         {:ok, reviews} <- fetch_pull_reviews(repo, pr),
         {:ok, current_feedback, feedback_source} <- fetch_current_feedback(repo, pr, comments, reviews) do
      {:ok,
       %{
         repo: repo,
         pr: pr,
         pr_number: pr_number(pr),
         pr_url: pr_url(pr),
         head_ref: head_ref(pr),
         head_sha: head_sha(pr),
         mergeable: pr_mergeable(pr),
         mergeable_state: pr_mergeable_state(pr),
         feedback: current_feedback,
         feedback_source: feedback_source
       }}
    end
  end

  defp no_pr_inspection(repo) do
    %{
      repo: repo,
      pr: nil,
      pr_number: nil,
      pr_url: nil,
      head_ref: nil,
      head_sha: nil,
      mergeable: nil,
      mergeable_state: nil,
      feedback: [],
      feedback_source: :no_pr
    }
  end

  defp issue_review_branch_candidates(%Issue{} = issue) do
    ([issue.branch_name] ++ description_review_branches(issue.description || ""))
    |> Enum.map(&clean_branch_name/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp description_review_branches(description) when is_binary(description) do
    [
      description_scalar_section(description, "Review Branch"),
      description_scalar_section(description, "Final Integration Branch"),
      description_scalar_section(description, "Integration Branch")
    ] ++ description_contract_branches(description)
  end

  defp description_review_branches(_description), do: []

  defp description_scalar_section(description, heading) do
    pattern = ~r/^##\s+#{Regex.escape(heading)}\s*\n(.*?)(?=^(?:##|###)\s+|\z)/ms

    case Regex.run(pattern, description || "", capture: :all_but_first) do
      [body] -> scalar_branch(body)
      _ -> ""
    end
  end

  defp description_contract_branches(description) do
    Regex.scan(
      ~r/^\s*(?:[-*]\s*)?(?:final\s+)?(?:review|integration)\s+branch\s*:\s*(.+)$/im,
      description || "",
      capture: :all_but_first
    )
    |> List.flatten()
    |> Enum.map(&scalar_branch/1)
  end

  defp scalar_branch(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map(&clean_branch_name/1)
    |> Enum.reject(&(&1 == ""))
    |> List.first()
    |> to_string()
  end

  defp scalar_branch(_text), do: ""

  defp clean_branch_name(branch) when is_binary(branch) do
    value =
      branch
      |> String.trim()
      |> String.trim_leading("*")
      |> String.trim_leading("-")
      |> String.trim()

    value =
      case Regex.run(~r/`([^`]+)`/, value, capture: :all_but_first) do
        [quoted] -> quoted
        _ -> value
      end

    value
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.replace(~r/^origin\//, "")
    |> String.trim()
  end

  defp clean_branch_name(_branch), do: ""

  @spec codex_review_request_pending?(String.t() | nil, map() | nil, list()) ::
          {:ok, boolean()} | {:error, term()}
  def codex_review_request_pending?(repo, pr, feedback)
      when is_binary(repo) and is_map(pr) and is_list(feedback) do
    with {:ok, comments} <- fetch_issue_comments(repo, pr) do
      {:ok, review_request_pending_after_feedback?(comments, feedback, pr)}
    end
  end

  def codex_review_request_pending?(_repo, _pr, _feedback), do: {:ok, false}

  @spec clean_codex_review_after_latest_request?(String.t() | nil, map() | nil) ::
          {:ok, boolean()} | {:error, term()}
  def clean_codex_review_after_latest_request?(repo, pr) when is_binary(repo) and is_map(pr) do
    with {:ok, comments} <- fetch_issue_comments(repo, pr) do
      {:ok, not is_nil(latest_clean_codex_review_after_latest_request_at(comments, pr))}
    end
  end

  def clean_codex_review_after_latest_request?(_repo, _pr), do: {:ok, false}

  @spec unresolved_review_thread_count(String.t() | nil, map() | nil) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def unresolved_review_thread_count(repo, pr) when is_binary(repo) and is_map(pr) do
    with {:ok, threads} <- fetch_pull_review_threads(repo, pr) do
      {:ok, Enum.count(threads, &active_review_thread?/1)}
    end
  end

  def unresolved_review_thread_count(_repo, _pr), do: {:error, :invalid_review_thread_request}

  @spec check_runs_state(String.t() | nil, String.t() | nil) ::
          {:ok, :passed | :pending | :failed | :none} | {:error, term()}
  def check_runs_state(repo, head_sha)
      when is_binary(repo) and repo != "" and is_binary(head_sha) and head_sha != "" do
    endpoint =
      "repos/#{repo}/commits/#{head_sha}/check-runs?" <>
        URI.encode_query(%{filter: "latest", per_page: 100})

    case github_api(endpoint) do
      {:ok, %{"check_runs" => runs}} when is_list(runs) -> {:ok, classify_check_runs(runs)}
      {:ok, _payload} -> {:error, :unexpected_check_runs_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  def check_runs_state(_repo, _head_sha), do: {:error, :invalid_check_runs_request}

  @spec refresh_pull_request(String.t() | nil, map() | nil) :: {:ok, map()} | {:error, term()}
  def refresh_pull_request(repo, pr) when is_binary(repo) and is_map(pr) do
    case pr_number(pr) do
      nil ->
        {:error, :missing_pull_request_number}

      number ->
        case github_api("repos/#{repo}/pulls/#{number}") do
          {:ok, live_pr} when is_map(live_pr) -> hydrate_pull_request_head_commit_required(repo, live_pr)
          {:ok, payload} -> {:error, {:unexpected_pull_request_payload, payload}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def refresh_pull_request(_repo, _pr), do: {:error, :invalid_pull_request_refresh}

  @spec request_codex_review(String.t() | nil, map() | nil, String.t()) ::
          {:ok, map()} | {:error, term()}
  def request_codex_review(repo, pr, body) when is_binary(repo) and is_map(pr) and is_binary(body) do
    create_issue_comment(repo, pr, body)
  end

  def request_codex_review(_repo, _pr, _body), do: {:error, :invalid_codex_review_request}

  @spec review_feedback_after_latest_codex_request?(String.t() | nil, map() | nil, list()) ::
          {:ok, boolean()} | {:error, term()}
  def review_feedback_after_latest_codex_request?(repo, pr, feedback)
      when is_binary(repo) and is_map(pr) and is_list(feedback) do
    with {:ok, comments} <- fetch_issue_comments(repo, pr) do
      {:ok, review_feedback_after_latest_request?(comments, feedback)}
    end
  end

  def review_feedback_after_latest_codex_request?(_repo, _pr, _feedback), do: {:ok, false}

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

  defp hydrate_pull_request_detail(_repo, nil), do: {:ok, nil}

  defp hydrate_pull_request_detail(repo, pr) when is_map(pr) do
    case pr_number(pr) do
      nil ->
        {:ok, pr}

      number ->
        case github_api("repos/#{repo}/pulls/#{number}") do
          {:ok, detail} when is_map(detail) ->
            {:ok, hydrate_pull_request_head_commit(repo, Map.merge(pr, detail))}

          _ ->
            {:ok, pr}
        end
    end
  end

  defp hydrate_pull_request_detail(_repo, pr), do: {:ok, pr}

  defp hydrate_pull_request_head_commit(repo, pr) when is_binary(repo) and is_map(pr) do
    case head_sha(pr) do
      sha when is_binary(sha) and sha != "" ->
        case github_api("repos/#{repo}/commits/#{sha}") do
          {:ok, commit} when is_map(commit) ->
            case commit_payload_committed_at(commit) do
              committed_at when is_binary(committed_at) and committed_at != "" ->
                Map.put(pr, "head_committed_at", committed_at)

              _ ->
                pr
            end

          _ ->
            pr
        end

      _ ->
        pr
    end
  rescue
    _error -> pr
  end

  defp hydrate_pull_request_head_commit(_repo, pr), do: pr

  defp hydrate_pull_request_head_commit_required(repo, pr) when is_binary(repo) and is_map(pr) do
    hydrated = hydrate_pull_request_head_commit(repo, pr)

    case head_committed_at(hydrated) do
      %DateTime{} -> {:ok, hydrated}
      _ -> {:error, :head_commit_unavailable}
    end
  end

  defp hydrate_pull_request_head_commit_required(_repo, _pr), do: {:error, :invalid_pull_request}

  defp commit_payload_committed_at(commit) when is_map(commit) do
    get_in(commit, ["commit", "committer", "date"]) ||
      get_in(commit, ["commit", "author", "date"]) ||
      commit["committed_at"] ||
      commit["created_at"]
  end

  defp commit_payload_committed_at(_commit), do: nil

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

  defp fetch_issue_comments(_repo, nil), do: {:ok, []}

  defp fetch_issue_comments(repo, pr) do
    case pr_number(pr) do
      nil -> {:ok, []}
      number -> fetch_issue_comments_page(repo, number, 1, [])
    end
  end

  defp fetch_issue_comments_page(repo, number, page, acc) do
    endpoint =
      "repos/#{repo}/issues/#{number}/comments?" <>
        URI.encode_query(%{per_page: @issue_comments_per_page, page: page})

    case github_api(endpoint) do
      {:ok, comments} when is_list(comments) ->
        page_size = length(comments)
        comments = normalize_issue_comments(comments)
        acc = acc ++ comments

        if page_size < @issue_comments_per_page do
          {:ok, acc}
        else
          fetch_issue_comments_page(repo, number, page + 1, acc)
        end

      {:ok, payload} ->
        {:error, {:unexpected_issue_comments_payload, payload}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_issue_comments(comments) do
    Enum.filter(comments, &is_map/1)
  end

  defp maybe_request_missing_codex_review(%Issue{} = issue, monitor, %{repo: repo, pr: pr}) do
    if review_state_issue?(issue, monitor) do
      case fetch_issue_comments(repo, pr) do
        {:ok, comments} ->
          if codex_review_handoff_present?(comments, pr) do
            :ok
          else
            request_missing_codex_review(issue, monitor, repo, pr)
          end

        {:error, reason} ->
          Logger.warning("Review monitor could not inspect PR issue comments for #{issue_context(issue)}: #{inspect(reason)}")
      end
    end
  end

  defp maybe_request_missing_codex_review(_issue, _monitor, _inspection), do: :ok

  defp maybe_advance_clean_codex_review(%Issue{} = issue, monitor, %{repo: repo, pr: pr} = inspection) do
    if review_state_issue?(issue, monitor) do
      case clean_codex_review_after_latest_request?(repo, pr) do
        {:ok, true} ->
          advance_clean_codex_review(issue, monitor, inspection)

        {:ok, false} ->
          maybe_request_missing_codex_review(issue, monitor, inspection)

        {:error, reason} ->
          Logger.warning("Review monitor could not inspect clean Codex result for #{issue_context(issue)}: #{inspect(reason)}")
      end
    end
  end

  defp maybe_advance_clean_codex_review(_issue, _monitor, _inspection), do: :ok

  defp advance_clean_codex_review(%Issue{} = issue, monitor, inspection) do
    case handoff_review_state(monitor) do
      {:ok, target_state} ->
        if normalize_state_name(issue.state) == normalize_state_name(target_state) do
          :ok
        else
          case Tracker.update_issue_state(issue.id, target_state) do
            :ok ->
              _ = Tracker.create_comment(issue.id, clean_codex_review_handoff_comment(issue, inspection, target_state))

              Logger.info("Review monitor advanced clean Codex handoff for #{issue_context(issue)} to #{target_state} PR ##{pr_number(inspection.pr)}")

            {:error, reason} ->
              Logger.warning("Review monitor could not advance clean Codex handoff for #{issue_context(issue)}: #{inspect(reason)}")
          end
        end

      {:error, reason} ->
        Logger.warning("Review monitor could not resolve clean Codex handoff state for #{issue_context(issue)}: #{inspect(reason)}")
    end
  end

  defp handoff_review_state(monitor) do
    monitor.states
    |> Enum.find_value(fn state ->
      state = state |> to_string() |> String.trim()
      if state == "", do: nil, else: state
    end)
    |> case do
      nil -> {:error, :missing_review_state}
      state -> {:ok, state}
    end
  end

  defp review_state_issue?(%Issue{state: state}, monitor) do
    issue_state = normalize_state_name(state)

    monitor.states
    |> Enum.map(&normalize_state_name/1)
    |> Enum.any?(&(&1 == issue_state))
  end

  defp normalize_state_name(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp codex_review_handoff_present?(comments, pr) when is_list(comments) do
    codex_review_request_after_head?(comments, pr) or
      not is_nil(latest_clean_codex_review_after_latest_request_at(comments, pr))
  end

  defp codex_review_handoff_present?(_comments, _pr), do: false

  defp codex_review_request_after_head?(comments, pr) do
    case latest_codex_review_request_at(comments) do
      %DateTime{} = request_at -> review_request_after_head?(request_at, pr)
      _ -> false
    end
  end

  defp request_missing_codex_review(%Issue{} = issue, monitor, repo, pr) do
    body = missing_codex_review_request_body(issue, pr)

    case create_issue_comment(repo, pr, body) do
      {:ok, _comment} ->
        _ = Tracker.create_comment(issue.id, missing_codex_review_tracker_comment(issue, monitor, pr))

        Logger.info("Review monitor requested missing Codex review for #{issue_context(issue)} PR ##{pr_number(pr)}")

      {:error, reason} ->
        Logger.warning("Review monitor could not request Codex review for #{issue_context(issue)}: #{inspect(reason)}")
    end
  end

  defp missing_codex_review_request_body(%Issue{} = issue, pr) do
    """
    @codex review

    Requested by Symphony review monitor because #{issue.identifier || issue.id || "this issue"} is in review state with PR ##{pr_number(pr)}, but no Codex review request or clean Codex result was found for the current handoff.
    """
    |> String.trim()
  end

  defp missing_codex_review_tracker_comment(%Issue{} = issue, monitor, pr) do
    """
    Symphony review monitor requested the missing Codex PR review instead of leaving this issue idle in `#{issue.state}`.

    - Issue: `#{issue.identifier}`
    - PR: ##{pr_number(pr)} #{pr_url(pr)}
    - State kept: `#{issue.state}`
    - Next action: wait for Codex review; if current-head feedback appears, the monitor will move this issue to `#{monitor.rework_state}` for review hardening.
    """
    |> String.trim()
  end

  defp clean_codex_review_handoff_comment(%Issue{} = issue, inspection, target_state) do
    pr = inspection.pr

    """
    Symphony review monitor observed a clean Codex review for the current PR head and advanced this issue to `#{target_state}`.

    - Issue: `#{issue.identifier}`
    - PR: ##{pr_number(pr)} #{pr_url(pr)}
    - Previous state: `#{issue.state}`
    - Next action: continue the configured Symphony delivery loop without starting a product-code worker for review polling.
    """
    |> String.trim()
  end

  defp fetch_current_feedback(_repo, nil, _comments, _reviews), do: {:ok, [], :no_pr}

  defp fetch_current_feedback(repo, pr, comments, reviews) do
    with {:ok, review_feedback, source} <- fetch_current_review_feedback(repo, pr, comments, reviews),
         {:ok, check_feedback} <- fetch_current_check_feedback(repo, pr) do
      {:ok, review_feedback ++ check_feedback, feedback_source_with_checks(source, check_feedback)}
    end
  end

  defp fetch_current_review_feedback(repo, pr, comments, reviews) do
    if review_threads_enabled?() do
      case fetch_pull_review_threads(repo, pr) do
        {:ok, threads} ->
          feedback =
            active_review_thread_feedback(threads) ++ current_head_reviews(pr, reviews)

          repo
          |> feedback_not_cleared_by_codex_clean_review(pr, feedback, :review_threads)

        {:error, reason} ->
          Logger.debug("Review monitor falling back to REST review feedback for #{repo}##{pr_number(pr)}: #{inspect(reason)}")
          fetch_rest_current_feedback(repo, pr, comments, reviews)
      end
    else
      fetch_rest_current_feedback(repo, pr, comments, reviews)
    end
  end

  defp feedback_source_with_checks(source, []), do: source
  defp feedback_source_with_checks(_source, _checks), do: :github_checks

  defp fetch_current_check_feedback(repo, pr) when is_binary(repo) and is_map(pr) do
    case head_sha(pr) do
      sha when is_binary(sha) and sha != "" ->
        endpoint =
          "repos/#{repo}/commits/#{sha}/check-runs?" <>
            URI.encode_query(%{filter: "latest", per_page: 100})

        case github_api(endpoint) do
          {:ok, %{"check_runs" => runs}} when is_list(runs) ->
            {:ok, failed_check_run_feedback(runs)}

          {:ok, payload} ->
            Logger.debug("Review monitor ignored unexpected check-runs payload for #{repo}@#{short_sha(sha)}: #{inspect(payload)}")
            {:ok, []}

          {:error, reason} ->
            Logger.debug("Review monitor could not inspect check runs for #{repo}@#{short_sha(sha)}: #{inspect(reason)}")
            {:ok, []}
        end

      _ ->
        {:ok, []}
    end
  end

  defp fetch_current_check_feedback(_repo, _pr), do: {:ok, []}

  defp maybe_fetch_current_check_feedback(repo, pr, opts) do
    if Keyword.get(opts, :include_checks?, true) do
      fetch_current_check_feedback(repo, pr)
    else
      {:ok, []}
    end
  end

  defp failed_check_run_feedback(runs) when is_list(runs) do
    runs
    |> Enum.filter(&failed_check_run?/1)
    |> Enum.map(&%{type: :check, payload: &1})
  end

  defp failed_check_run_feedback(_runs), do: []

  defp failed_check_run?(run) when is_map(run) do
    conclusion =
      run
      |> Map.get("conclusion", "")
      |> to_string()
      |> String.downcase()

    status =
      run
      |> Map.get("status", "")
      |> to_string()
      |> String.downcase()

    status == "completed" and conclusion in ["failure", "timed_out", "action_required", "cancelled"]
  end

  defp failed_check_run?(_run), do: false

  defp classify_check_runs([]), do: :none

  defp classify_check_runs(runs) do
    cond do
      Enum.any?(runs, &failed_check_run?/1) -> :failed
      Enum.any?(runs, &(normalize_check_value(&1["status"]) != "completed")) -> :pending
      Enum.all?(runs, &(normalize_check_value(&1["conclusion"]) in ["success", "neutral", "skipped"])) -> :passed
      true -> :failed
    end
  end

  defp normalize_check_value(value), do: value |> to_string() |> String.downcase()

  defp fetch_rest_current_feedback(repo, pr, comments, reviews) do
    repo
    |> feedback_not_cleared_by_codex_clean_review(
      pr,
      current_head_comments(pr, comments) ++ current_head_reviews(pr, reviews),
      :rest_current_head
    )
  end

  defp review_threads_enabled? do
    is_function(Application.get_env(:symphony_elixir, :github_graphql_runner), 2) or
      is_nil(Application.get_env(:symphony_elixir, :github_api_runner))
  end

  defp fetch_pull_review_threads(repo, pr) do
    with number when not is_nil(number) <- pr_number(pr),
         {:ok, {owner, name}} <- split_repo(repo) do
      fetch_pull_review_threads_page(owner, name, number, nil, [])
    else
      nil -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_pull_review_threads_page(owner, name, number, after_cursor, acc) do
    variables = %{
      "owner" => owner,
      "name" => name,
      "number" => number,
      "after" => after_cursor
    }

    with {:ok, response} <- github_graphql(@review_threads_query, variables),
         %{"nodes" => nodes, "pageInfo" => page_info} <-
           get_in(response, ["data", "repository", "pullRequest", "reviewThreads"]) do
      acc = acc ++ nodes

      if page_info["hasNextPage"] == true and is_binary(page_info["endCursor"]) do
        fetch_pull_review_threads_page(owner, name, number, page_info["endCursor"], acc)
      else
        {:ok, acc}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unexpected_review_threads_payload}
    end
  end

  defp active_review_thread_feedback(threads) when is_list(threads) do
    threads
    |> Enum.filter(&active_review_thread?/1)
    |> Enum.map(&%{type: :thread, payload: &1})
  end

  defp active_review_thread_feedback(_threads), do: []

  defp active_review_thread?(thread) when is_map(thread) do
    thread["isResolved"] != true and thread["isOutdated"] != true
  end

  defp active_review_thread?(_thread), do: false

  defp feedback_not_cleared_by_codex_clean_review(_repo, _pr, [], source), do: {:ok, [], source}

  defp feedback_not_cleared_by_codex_clean_review(repo, pr, feedback, source) when is_list(feedback) do
    comments =
      case fetch_issue_comments(repo, pr) do
        {:ok, comments} when is_list(comments) -> comments
        _ -> []
      end

    feedback =
      case latest_clean_codex_review_after_latest_request_at(comments, pr) do
        %DateTime{} = clean_at ->
          Enum.filter(feedback, fn item ->
            case review_feedback_created_at(item) do
              %DateTime{} = feedback_at -> DateTime.compare(feedback_at, clean_at) == :gt
              _ -> true
            end
          end)

        _ ->
          feedback
      end

    {:ok, feedback, source}
  end

  defp feedback_not_cleared_by_codex_clean_review(_repo, _pr, feedback, source), do: {:ok, feedback, source}

  defp review_request_pending_after_feedback?(comments, feedback, pr) do
    with %DateTime{} = request_at <- latest_codex_review_request_at(comments),
         true <- review_request_after_head?(request_at, pr),
         false <- stale_codex_review_request?(request_at),
         feedback_at <- latest_review_feedback_at(feedback) do
      case feedback_at do
        %DateTime{} = feedback_at ->
          DateTime.compare(request_at, feedback_at) == :gt

        nil ->
          is_nil(latest_clean_codex_review_after_latest_request_at(comments))
      end
    else
      _ -> false
    end
  end

  defp stale_codex_review_request?(%DateTime{} = request_at) do
    case review_request_stale_after_ms() do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
        DateTime.diff(DateTime.utc_now(), request_at, :millisecond) >= timeout_ms

      _ ->
        false
    end
  end

  defp stale_codex_review_request?(_request_at), do: false

  defp review_request_stale_after_ms do
    case Application.get_env(:symphony_elixir, :codex_review_request_stale_after_ms, :config) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
        timeout_ms

      :config ->
        Config.settings!().review_monitor.request_stale_after_ms

      _ ->
        nil
    end
  rescue
    _error -> nil
  end

  defp review_request_after_head?(%DateTime{} = request_at, pr) when is_map(pr) do
    case head_committed_at(pr) do
      %DateTime{} = head_at -> DateTime.compare(request_at, head_at) == :gt
      _ -> true
    end
  end

  defp review_request_after_head?(_request_at, _pr), do: true

  defp review_feedback_after_latest_request?(comments, feedback) do
    with %DateTime{} = request_at <- latest_codex_review_request_at(comments),
         %DateTime{} = feedback_at <- latest_review_feedback_at(feedback) do
      DateTime.compare(feedback_at, request_at) == :gt
    else
      _ -> false
    end
  end

  defp latest_codex_review_request_at(comments) when is_list(comments) do
    comments
    |> Enum.filter(&codex_review_request_comment?/1)
    |> Enum.map(&created_at/1)
    |> latest_datetime()
  end

  defp latest_codex_review_request_at(_comments), do: nil

  defp codex_review_request_comment?(%{"body" => body}) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.any?(fn line ->
      line
      |> String.trim()
      |> String.match?(~r/^@codex\s+review(?:\b|$)/i)
    end)
  end

  defp codex_review_request_comment?(_comment), do: false

  defp latest_clean_codex_review_after_latest_request_at(comments) when is_list(comments) do
    with %DateTime{} = request_at <- latest_codex_review_request_at(comments) do
      comments
      |> Enum.filter(&clean_codex_review_comment?/1)
      |> Enum.map(&created_at/1)
      |> Enum.filter(fn
        %DateTime{} = clean_at -> DateTime.compare(clean_at, request_at) == :gt
        _ -> false
      end)
      |> latest_datetime()
    end
  end

  defp latest_clean_codex_review_after_latest_request_at(_comments), do: nil

  defp latest_clean_codex_review_after_latest_request_at(comments, pr) when is_list(comments) do
    with %DateTime{} = clean_at <- latest_clean_codex_review_after_latest_request_at(comments),
         true <- review_request_after_head?(clean_at, pr) do
      clean_at
    else
      _ -> nil
    end
  end

  defp latest_clean_codex_review_after_latest_request_at(_comments, _pr), do: nil

  defp head_committed_at(%{} = pr) do
    pr
    |> Map.get("head_committed_at", Map.get(pr, :head_committed_at))
    |> datetime_from_iso8601()
  end

  defp head_committed_at(_pr), do: nil

  defp clean_codex_review_comment?(%{"body" => body}) when is_binary(body) do
    body
    |> String.trim()
    |> String.match?(~r/^Codex Review:\s*(Didn['’]?t|Did not) find any major issues\b/i)
  end

  defp clean_codex_review_comment?(_comment), do: false

  defp latest_review_feedback_at(feedback) when is_list(feedback) do
    feedback
    |> Enum.map(&review_feedback_created_at/1)
    |> latest_datetime()
  end

  defp latest_review_feedback_at(_feedback), do: nil

  defp review_feedback_created_at(%{type: :thread, payload: thread}) do
    thread
    |> thread_latest_comment()
    |> created_at()
  end

  defp review_feedback_created_at(%{type: :comment, payload: comment}), do: created_at(comment)

  defp review_feedback_created_at(%{type: :review, payload: review}) do
    created_at(review) || datetime_from_iso8601(review["submitted_at"])
  end

  defp review_feedback_created_at(%{type: :check, payload: check}) do
    datetime_from_iso8601(check["completed_at"] || check["started_at"] || check["created_at"])
  end

  defp review_feedback_created_at(_feedback), do: nil

  defp created_at(%{} = payload) do
    datetime_from_iso8601(payload["createdAt"] || payload["created_at"])
  end

  defp created_at(_payload), do: nil

  defp latest_datetime(datetimes) do
    datetimes
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp datetime_from_iso8601(value) when is_binary(value) and value != "" do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp datetime_from_iso8601(_value), do: nil

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
    |> Enum.map(&%{type: :review, payload: review_feedback_payload(&1, head_sha)})
  end

  defp current_head_reviews(_pr, _reviews), do: []

  defp review_feedback_payload(review, head_sha) when is_map(review) do
    review
    |> Map.merge(review_body_location(review["body"], head_sha))
  end

  defp review_feedback_payload(review, _head_sha), do: review

  defp review_body_location(body, head_sha) when is_binary(body) do
    case Regex.run(github_blob_line_regex(head_sha), body, capture: :all_but_first) do
      [path, line] ->
        %{
          "path" => path,
          "line" => String.to_integer(line),
          "html_url" => review_body_first_blob_url(body, head_sha)
        }

      _ ->
        %{}
    end
  end

  defp review_body_location(_body, _head_sha), do: %{}

  defp github_blob_line_regex(head_sha) when is_binary(head_sha) and head_sha != "" do
    ~r{https://github\.com/[^/\s]+/[^/\s]+/blob/#{Regex.escape(head_sha)}/([^#\s]+)#L(\d+)(?:-L\d+)?}
  end

  defp github_blob_line_regex(_head_sha) do
    ~r{https://github\.com/[^/\s]+/[^/\s]+/blob/[^/\s]+/([^#\s]+)#L(\d+)(?:-L\d+)?}
  end

  defp review_body_first_blob_url(body, head_sha) when is_binary(body) do
    case Regex.run(~r{https://github\.com/[^)\s]+/blob/#{Regex.escape(to_string(head_sha))}/[^)\s]+#L\d+(?:-L\d+)?}, body) do
      [url] -> url
      _ -> nil
    end
  end

  defp review_body_first_blob_url(_body, _head_sha), do: nil

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

    MapSet.member?(@review_feedback_states, state) or
      (state == "COMMENTED" and body_level_review_feedback?(review))
  end

  defp feedback_review?(_review), do: false

  defp body_level_review_feedback?(%{"body" => body, "commit_id" => head_sha})
       when is_binary(body) and is_binary(head_sha) do
    Regex.match?(github_blob_line_regex(head_sha), body)
  end

  defp body_level_review_feedback?(_review), do: false

  defp build_feedback(repo, pr, feedback) do
    %{
      repo: repo,
      pr_number: pr_number(pr),
      pr_url: pr["html_url"],
      head_sha: head_sha(pr),
      feedback: feedback
    }
  end

  defp build_merge_conflict_feedback(%{repo: repo, pr: pr} = inspection) do
    %{
      repo: repo,
      pr_number: pr_number(pr),
      pr_url: pr_url(pr),
      head_sha: head_sha(pr),
      feedback: [
        %{
          type: :mergeability,
          payload: %{
            "mergeable" => Map.get(inspection, :mergeable),
            "mergeable_state" => Map.get(inspection, :mergeable_state),
            "html_url" => pr_url(pr)
          }
        }
      ]
    }
  end

  defp merge_conflict_inspection?(%{mergeable: false, mergeable_state: state}) do
    normalize_mergeable_state(state) in ["dirty", "conflicting"]
  end

  defp merge_conflict_inspection?(_inspection), do: false

  defp normalize_mergeable_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_mergeable_state(_state), do: ""

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
    - Marker: `review_rework_needed`
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

  defp feedback_item_summary(%{type: :mergeability, payload: payload}) do
    state =
      payload
      |> Map.get("mergeable_state")
      |> to_string()
      |> String.trim()

    [
      "PR mergeability",
      "mergeable_state=#{if state == "", do: "unknown", else: state}",
      payload["html_url"]
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" - ")
  end

  defp feedback_item_summary(%{type: :review, payload: review}) do
    ["Review #{review["state"]}", first_body_line(review["body"]), review["html_url"]]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" - ")
  end

  defp feedback_item_summary(%{type: :thread, payload: thread}) do
    comment = thread_latest_comment(thread)

    location =
      [
        comment["path"],
        line_fragment(comment)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(":")

    [location, first_body_line(comment["body"]), comment["url"]]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" - ")
  end

  defp feedback_item_summary(%{type: :check, payload: check}) do
    output = check["output"] || %{}

    [
      "Check #{check["name"] || check["workflow_name"] || "unknown"} #{check["conclusion"] || check["status"]}",
      output["title"] || output["summary"],
      check["details_url"] || check["html_url"]
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" - ")
  end

  defp feedback_item_summary(_item), do: "Review feedback"

  defp thread_latest_comment(%{"comments" => %{"nodes" => comments}}) when is_list(comments) do
    List.last(comments) || %{}
  end

  defp thread_latest_comment(_thread), do: %{}

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

  defp create_issue_comment(_repo, nil, _body), do: {:error, :missing_pull_request}

  defp create_issue_comment(repo, pr, body) when is_binary(repo) and is_binary(body) do
    case pr_number(pr) do
      nil ->
        {:error, :missing_pr_number}

      number ->
        github_api_post("repos/#{repo}/issues/#{number}/comments", %{"body" => body})
    end
  end

  defp create_issue_comment(_repo, _pr, _body), do: {:error, :invalid_issue_comment_request}

  defp github_api_post(endpoint, fields) do
    case github_api_post_runner().(endpoint, fields) do
      {:ok, decoded} ->
        {:ok, decoded}

      {output, 0} when is_binary(output) ->
        Jason.decode(output)

      {output, exit_code} ->
        {:error, {:github_api_post_failed, exit_code, summarize_output(output)}}

      other ->
        {:error, {:github_api_post_unexpected_result, other}}
    end
  rescue
    error -> {:error, {:github_api_post_exception, Exception.message(error)}}
  end

  defp github_api_post_runner do
    case Application.get_env(:symphony_elixir, :github_api_post_runner) do
      runner when is_function(runner, 2) ->
        runner

      _ ->
        fn endpoint, fields ->
          args =
            ["api", endpoint]
            |> Kernel.++(
              fields
              |> Enum.flat_map(fn {key, value} -> ["-f", "#{key}=#{value}"] end)
            )

          System.cmd("gh", args, stderr_to_stdout: true)
        end
    end
  end

  defp github_graphql(query, variables) when is_binary(query) and is_map(variables) do
    case github_graphql_runner().(query, variables) do
      {:ok, decoded} ->
        {:ok, decoded}

      {output, 0} when is_binary(output) ->
        Jason.decode(output)

      {output, exit_code} ->
        {:error, {:github_graphql_failed, exit_code, summarize_output(output)}}

      other ->
        {:error, {:github_graphql_unexpected_result, other}}
    end
  rescue
    error -> {:error, {:github_graphql_exception, Exception.message(error)}}
  end

  defp github_graphql_runner do
    case Application.get_env(:symphony_elixir, :github_graphql_runner) do
      runner when is_function(runner, 2) ->
        runner

      _ ->
        fn query, variables ->
          args =
            ["api", "graphql"]
            |> Kernel.++(
              variables
              |> Enum.reject(fn {_key, value} -> is_nil(value) end)
              |> Enum.flat_map(fn {key, value} -> ["-F", "#{key}=#{value}"] end)
            )
            |> Kernel.++(["-f", "query=#{query}"])

          System.cmd("gh", args, stderr_to_stdout: true)
        end
    end
  end

  defp split_repo(repo) when is_binary(repo) do
    case String.split(repo, "/", parts: 2) do
      [owner, name] when owner != "" and name != "" -> {:ok, {owner, name}}
      _ -> {:error, {:invalid_github_repo, repo}}
    end
  end

  defp split_repo(repo), do: {:error, {:invalid_github_repo, repo}}

  defp pr_number(pr) when is_map(pr) do
    case pr["number"] do
      number when is_integer(number) -> number
      number when is_binary(number) -> number
      _ -> nil
    end
  end

  defp pr_number(_pr), do: nil

  defp pr_url(pr) when is_map(pr), do: pr["html_url"]
  defp pr_url(_pr), do: nil

  defp head_ref(pr) when is_map(pr), do: get_in(pr, ["head", "ref"])
  defp head_ref(_pr), do: nil

  defp head_sha(pr) when is_map(pr), do: get_in(pr, ["head", "sha"])
  defp head_sha(_pr), do: nil

  defp pr_mergeable(%{"mergeable" => mergeable}) when is_boolean(mergeable), do: mergeable
  defp pr_mergeable(%{mergeable: mergeable}) when is_boolean(mergeable), do: mergeable
  defp pr_mergeable(_pr), do: nil

  defp pr_mergeable_state(pr) when is_map(pr) do
    (pr["mergeable_state"] || pr[:mergeable_state] || pr["mergeStateStatus"] || pr[:mergeStateStatus])
    |> case do
      state when is_binary(state) -> String.trim(state)
      _ -> nil
    end
  end

  defp pr_mergeable_state(_pr), do: nil

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
