defmodule SymphonyElixir.RuntimeRequest do
  @moduledoc """
  Reads and consumes durable worker-to-controller transition requests.

  Requests are single-use and must have been appended after the current Git
  checkpoint. This prevents a request written for an older head from being
  replayed after a later commit or runtime restart.
  """

  @events_path ".orocsy/delivery/events/events.jsonl"
  @authority "symphony.runtime.transition-controller"

  alias SymphonyElixir.ControllerEvidence

  @type request :: map()

  @spec latest_unprocessed(String.t(), String.t()) :: {:ok, request()} | :none | {:stale, request(), term()}
  def latest_unprocessed(workspace, event_type)
      when is_binary(workspace) and is_binary(event_type) do
    events = decoded_events(workspace)
    processed_ids = processed_request_ids(events)

    events
    |> Enum.reverse()
    |> Enum.find(fn event ->
      event["event"] == event_type and
        event["status"] in ["requested", nil] and
        valid_request_id?(event["event_id"]) and
        not MapSet.member?(processed_ids, event["event_id"])
    end)
    |> classify_for_current_head(workspace)
  end

  def latest_unprocessed(_workspace, _event_type), do: :none

  @spec mark_processed(String.t(), request(), String.t()) :: :ok
  def mark_processed(workspace, request, status), do: mark_processed(workspace, request, status, %{})

  @spec mark_processed(String.t(), request(), String.t(), map()) :: :ok
  def mark_processed(workspace, request, status, attributes)
      when is_binary(workspace) and is_map(request) and is_binary(status) and is_map(attributes) do
    event =
      ControllerEvidence.sign(
        Map.merge(attributes, %{
          "schema_version" => 1,
          "event" => "runtime.request.processed",
          "authority" => @authority,
          "request_event" => request["event"],
          "request_event_id" => request["event_id"],
          "status" => status,
          "ts" => now()
        })
      )

    append_event(workspace, event)
  end

  def mark_processed(_workspace, _request, _status, _attributes), do: :ok

  defp classify_for_current_head(nil, _workspace), do: :none

  defp classify_for_current_head(request, workspace) do
    with {:ok, head_sha} <- git(workspace, ["rev-parse", "HEAD"]),
         {:ok, committed_at} <- head_committed_at(workspace),
         {:ok, requested_at} <- parse_timestamp(request["ts"]),
         true <- DateTime.compare(requested_at, committed_at) in [:eq, :gt] do
      {:ok, Map.put(request, "controller_head_sha", head_sha)}
    else
      reason -> {:stale, request, stale_reason(reason)}
    end
  end

  defp stale_reason(false), do: :request_predates_current_head
  defp stale_reason({:error, reason}), do: reason

  defp head_committed_at(workspace) do
    case git(workspace, ["show", "-s", "--format=%cI", "HEAD"]) do
      {:ok, value} -> parse_timestamp(value)
      error -> error
    end
  end

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> {:ok, timestamp}
      _ -> {:error, :invalid_request_timestamp}
    end
  end

  defp parse_timestamp(_value), do: {:error, :missing_request_timestamp}

  defp processed_request_ids(events) do
    events
    |> Enum.flat_map(fn
      %{"event" => "runtime.request.processed", "request_event_id" => request_id} = event
      when is_binary(request_id) and request_id != "" ->
        if ControllerEvidence.valid?(event), do: [request_id], else: []

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp valid_request_id?(value), do: is_binary(value) and value != ""

  defp decoded_events(workspace) do
    path = Path.join(workspace, @events_path)

    if File.regular?(path) do
      path
      |> File.stream!()
      |> Enum.flat_map(fn line ->
        case Jason.decode(String.trim(line)) do
          {:ok, event} when is_map(event) -> [event]
          _ -> []
        end
      end)
    else
      []
    end
  end

  defp append_event(workspace, event) do
    path = Path.join(workspace, @events_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(event) <> "\n", [:append])
    :ok
  end

  defp git(workspace, args) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:git_failed, args, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:git_exception, Exception.message(error)}}
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
