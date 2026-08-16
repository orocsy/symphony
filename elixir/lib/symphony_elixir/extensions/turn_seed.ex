defmodule SymphonyElixir.Extensions.TurnSeed do
  @moduledoc "Immutable extension authority captured before an app-server turn starts."

  alias SymphonyElixir.Tracker.Issue

  @enforce_keys [
    :issue,
    :workspace,
    :worker_host,
    :thread_id,
    :registry_revision,
    :options
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          issue: Issue.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          thread_id: String.t(),
          registry_revision: String.t(),
          options: map()
        }
end
