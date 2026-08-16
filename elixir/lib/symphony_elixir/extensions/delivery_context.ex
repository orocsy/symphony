defmodule SymphonyElixir.Extensions.DeliveryContext do
  @moduledoc "Immutable facade-owned context for a workspace-ready delivery."

  alias SymphonyElixir.Tracker.Issue

  @enforce_keys [
    :issue,
    :workspace,
    :worker_host,
    :attempt,
    :registry_revision,
    :options
  ]
  defstruct [:issue, :workspace, :worker_host, :attempt, :registry_revision, :options]

  @type t :: %__MODULE__{
          issue: Issue.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          attempt: non_neg_integer(),
          registry_revision: String.t(),
          options: map()
        }
end
