defmodule SymphonyElixir.Extensions.CommandAuthorization do
  @moduledoc "Adapter contract for one parsed command authorization intent."

  alias SymphonyElixir.Extensions.ExtensionFailure

  @type result ::
          :kernel_default
          | :allow
          | {:allow_once, term()}
          | {:deny, term()}
          | {:error, ExtensionFailure.t()}

  @callback authorize(term(), term()) :: result()
end
