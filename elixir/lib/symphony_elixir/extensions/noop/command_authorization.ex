defmodule SymphonyElixir.Extensions.Noop.CommandAuthorization do
  @moduledoc "Neutral authorization adapter that preserves the kernel path."

  @behaviour SymphonyElixir.Extensions.CommandAuthorization

  @impl true
  @spec authorize(term(), term()) :: :kernel_default
  def authorize(_intent, _context), do: :kernel_default
end
