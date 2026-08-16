defmodule SymphonyElixir.Extensions.AdmissionContext do
  @moduledoc "Immutable facade-owned context for a dispatch-admission decision."

  @enforce_keys [:attempt, :registry_revision, :options]
  defstruct [:attempt, :registry_revision, :options]

  @type t :: %__MODULE__{
          attempt: non_neg_integer(),
          registry_revision: String.t(),
          options: map()
        }
end
