defmodule SymphonyElixir.Extensions.Noop.CommandAuthorization do
  @moduledoc "Neutral authorization adapter that preserves the kernel path."

  @behaviour SymphonyElixir.Extensions.CommandAuthorization

  alias SymphonyElixir.Extensions.CommandIntent
  alias SymphonyElixir.Extensions.TurnContext

  @impl true
  @spec authorize(CommandIntent.t(), TurnContext.t()) :: :kernel_default
  def authorize(_intent, _context), do: :kernel_default
end
