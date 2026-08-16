defmodule SymphonyElixir.Extensions.CommandAuthorization do
  @moduledoc "Adapter contract for one parsed command authorization intent."

  alias SymphonyElixir.Extensions.CommandIntent
  alias SymphonyElixir.Extensions.ExtensionFailure
  alias SymphonyElixir.Extensions.TurnContext

  @type result ::
          :kernel_default
          | :allow
          | {:allow_once, term()}
          | {:deny, term()}
          | {:error, ExtensionFailure.t()}

  @callback authorize(CommandIntent.t(), TurnContext.t()) :: result()
end
