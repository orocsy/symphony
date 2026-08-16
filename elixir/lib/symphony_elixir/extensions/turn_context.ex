defmodule SymphonyElixir.Extensions.TurnContext do
  @moduledoc "Immutable extension authority bound to one app-server turn."

  alias SymphonyElixir.Tracker.Issue

  @enforce_keys [
    :issue,
    :workspace,
    :worker_host,
    :thread_id,
    :turn_id,
    :registry_revision,
    :options
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          issue: Issue.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          thread_id: String.t(),
          turn_id: String.t(),
          registry_revision: String.t(),
          options: map()
        }
end
