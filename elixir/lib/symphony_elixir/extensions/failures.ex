defmodule SymphonyElixir.Extensions.ExtensionFailure do
  @moduledoc "Typed failure returned by generic extension decisions."

  @enforce_keys [:code, :interface]
  defstruct [:code, :interface, :adapter, :registry_revision, :reason]

  @type t :: %__MODULE__{
          code: atom(),
          interface: atom() | nil,
          adapter: module() | String.t() | nil,
          registry_revision: String.t() | nil,
          reason: atom() | map() | nil
        }
end

defmodule SymphonyElixir.Extensions.ControllerFailure do
  @moduledoc "Typed failure returned by the delivery-controller boundary."

  @enforce_keys [:code, :interface]
  defstruct [:code, :interface, :adapter, :registry_revision, :reason]

  @type t :: %__MODULE__{
          code: atom(),
          interface: :delivery_controller,
          adapter: module() | nil,
          registry_revision: String.t() | nil,
          reason: atom() | map() | nil
        }
end

defmodule SymphonyElixir.Extensions.ObserverFailure do
  @moduledoc "Typed failure returned by an observer adapter."

  @enforce_keys [:code, :interface]
  defstruct [:code, :interface, :adapter, :registry_revision, :reason]

  @type t :: %__MODULE__{
          code: atom(),
          interface: :delivery_observer,
          adapter: module() | nil,
          registry_revision: String.t() | nil,
          reason: atom() | map() | nil
        }
end
