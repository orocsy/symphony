defmodule SymphonyElixir.Extensions.CommandIntent.CommandExecution.ReadAction do
  @moduledoc false
  @enforce_keys [:command, :name, :path]
  defstruct @enforce_keys
  @type t :: %__MODULE__{command: String.t(), name: String.t(), path: Path.t()}
end

defmodule SymphonyElixir.Extensions.CommandIntent.CommandExecution.ListFilesAction do
  @moduledoc false
  @enforce_keys [:command, :path]
  defstruct @enforce_keys
  @type t :: %__MODULE__{command: String.t(), path: Path.t() | nil}
end

defmodule SymphonyElixir.Extensions.CommandIntent.CommandExecution.SearchAction do
  @moduledoc false
  @enforce_keys [:command, :path, :query]
  defstruct @enforce_keys
  @type t :: %__MODULE__{command: String.t(), path: Path.t() | nil, query: String.t() | nil}
end

defmodule SymphonyElixir.Extensions.CommandIntent.CommandExecution.UnknownAction do
  @moduledoc false
  @enforce_keys [:command]
  defstruct @enforce_keys
  @type t :: %__MODULE__{command: String.t()}
end

defmodule SymphonyElixir.Extensions.CommandIntent.CommandExecution.NetworkApproval do
  @moduledoc false
  @enforce_keys [:host, :protocol]
  defstruct @enforce_keys
  @type protocol :: :http | :https | :socks5_tcp | :socks5_udp
  @type t :: %__MODULE__{host: String.t(), protocol: protocol()}
end

defmodule SymphonyElixir.Extensions.CommandIntent.CommandExecution.NetworkAmendment do
  @moduledoc false
  @enforce_keys [:action, :host]
  defstruct @enforce_keys
  @type t :: %__MODULE__{action: :allow | :deny, host: String.t()}
end

defmodule SymphonyElixir.Extensions.CommandIntent.CommandExecution do
  @moduledoc false

  alias __MODULE__.{
    ListFilesAction,
    NetworkAmendment,
    NetworkApproval,
    ReadAction,
    SearchAction,
    UnknownAction
  }

  @enforce_keys [
    :approval_id,
    :command,
    :command_actions,
    :cwd,
    :item_id,
    :network_approval,
    :proposed_execpolicy_amendment,
    :proposed_network_policy_amendments,
    :reason,
    :thread_id,
    :turn_id
  ]
  defstruct @enforce_keys

  @type action :: ReadAction.t() | ListFilesAction.t() | SearchAction.t() | UnknownAction.t()
  @type t :: %__MODULE__{
          approval_id: String.t() | nil,
          command: String.t() | nil,
          command_actions: [action()] | nil,
          cwd: Path.t() | nil,
          item_id: String.t(),
          network_approval: NetworkApproval.t() | nil,
          proposed_execpolicy_amendment: [String.t()] | nil,
          proposed_network_policy_amendments: [NetworkAmendment.t()] | nil,
          reason: String.t() | nil,
          thread_id: String.t(),
          turn_id: String.t()
        }
end

defmodule SymphonyElixir.Extensions.CommandIntent.FileChangeApproval do
  @moduledoc false
  @enforce_keys [:grant_root, :item_id, :reason, :thread_id, :turn_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          grant_root: Path.t() | nil,
          item_id: String.t(),
          reason: String.t() | nil,
          thread_id: String.t(),
          turn_id: String.t()
        }
end

defmodule SymphonyElixir.Extensions.CommandIntent.LegacyExecCommand.ReadAction do
  @moduledoc false
  @enforce_keys [:command, :name, :path]
  defstruct @enforce_keys
  @type t :: %__MODULE__{command: String.t(), name: String.t(), path: Path.t()}
end

defmodule SymphonyElixir.Extensions.CommandIntent.LegacyExecCommand.ListFilesAction do
  @moduledoc false
  @enforce_keys [:command, :path]
  defstruct @enforce_keys
  @type t :: %__MODULE__{command: String.t(), path: Path.t() | nil}
end

defmodule SymphonyElixir.Extensions.CommandIntent.LegacyExecCommand.SearchAction do
  @moduledoc false
  @enforce_keys [:command, :path, :query]
  defstruct @enforce_keys
  @type t :: %__MODULE__{command: String.t(), path: Path.t() | nil, query: String.t() | nil}
end

defmodule SymphonyElixir.Extensions.CommandIntent.LegacyExecCommand.UnknownAction do
  @moduledoc false
  @enforce_keys [:command]
  defstruct @enforce_keys
  @type t :: %__MODULE__{command: String.t()}
end

defmodule SymphonyElixir.Extensions.CommandIntent.LegacyExecCommand do
  @moduledoc false

  alias __MODULE__.{ListFilesAction, ReadAction, SearchAction, UnknownAction}

  @enforce_keys [
    :approval_id,
    :argv,
    :call_id,
    :conversation_id,
    :cwd,
    :parsed_actions,
    :reason
  ]
  defstruct @enforce_keys

  @type action :: ReadAction.t() | ListFilesAction.t() | SearchAction.t() | UnknownAction.t()
  @type t :: %__MODULE__{
          approval_id: String.t() | nil,
          argv: [String.t()],
          call_id: String.t(),
          conversation_id: String.t(),
          cwd: Path.t(),
          parsed_actions: [action()],
          reason: String.t() | nil
        }
end

defmodule SymphonyElixir.Extensions.CommandIntent.LegacyApplyPatch.TargetChange do
  @moduledoc false
  @enforce_keys [:move_path, :operation, :path]
  defstruct @enforce_keys
  @type t :: %__MODULE__{move_path: Path.t() | nil, operation: :add | :delete | :update, path: Path.t()}
end

defmodule SymphonyElixir.Extensions.CommandIntent.LegacyApplyPatch do
  @moduledoc false

  alias __MODULE__.TargetChange

  @enforce_keys [:call_id, :changes, :conversation_id, :grant_root, :reason]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          call_id: String.t(),
          changes: [TargetChange.t()],
          conversation_id: String.t(),
          grant_root: Path.t() | nil,
          reason: String.t() | nil
        }
end

defmodule SymphonyElixir.Extensions.CommandIntent.DynamicToolCall do
  @moduledoc false
  @enforce_keys [:arguments, :arguments_validated?, :call_id, :thread_id, :tool, :turn_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          arguments: term(),
          arguments_validated?: false,
          call_id: String.t(),
          thread_id: String.t(),
          tool: String.t(),
          turn_id: String.t()
        }
end

defmodule SymphonyElixir.Extensions.CommandIntent.ToolApproval.Question do
  @moduledoc false
  @enforce_keys [:id, :option_labels]
  defstruct @enforce_keys
  @type t :: %__MODULE__{id: String.t(), option_labels: [String.t()]}
end

defmodule SymphonyElixir.Extensions.CommandIntent.ToolApproval do
  @moduledoc false

  alias __MODULE__.Question

  @enforce_keys [:item_id, :questions, :thread_id, :turn_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          item_id: String.t(),
          questions: [Question.t()],
          thread_id: String.t(),
          turn_id: String.t()
        }
end

defmodule SymphonyElixir.Extensions.CommandIntent do
  @moduledoc "Closed, parsed authorization intent presented to one extension adapter."

  alias __MODULE__.{
    CommandExecution,
    DynamicToolCall,
    FileChangeApproval,
    LegacyApplyPatch,
    LegacyExecCommand,
    ToolApproval
  }

  @enforce_keys [:request_id, :operation]
  defstruct @enforce_keys

  @type request_id :: String.t() | integer()
  @type operation ::
          CommandExecution.t()
          | FileChangeApproval.t()
          | LegacyExecCommand.t()
          | LegacyApplyPatch.t()
          | DynamicToolCall.t()
          | ToolApproval.t()
  @type t :: %__MODULE__{request_id: request_id(), operation: operation()}
end
