defmodule SymphonyElixir.Extensions.DispatchAdmission do
  @moduledoc "Adapter contract for pre-claim issue admission."

  alias SymphonyElixir.Extensions.ExtensionFailure
  alias SymphonyElixir.Tracker.Issue

  @type result ::
          :kernel_default
          | {:admit, term()}
          | {:reject, term()}
          | {:error, ExtensionFailure.t()}

  @callback evaluate(Issue.t(), term()) :: result()
end
