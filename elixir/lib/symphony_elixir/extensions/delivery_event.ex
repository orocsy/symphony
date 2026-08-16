defmodule SymphonyElixir.Extensions.DeliveryEvent do
  @moduledoc "Closed lifecycle event delivered to a delivery controller."

  @enforce_keys [:type]
  defstruct [:type]

  @type t :: %__MODULE__{type: :workspace_ready}
end
