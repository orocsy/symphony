defmodule SymphonyElixir.Extensions.Noop.DeliveryController do
  @moduledoc "Neutral delivery adapter that preserves the kernel path."

  @behaviour SymphonyElixir.Extensions.DeliveryController

  @impl true
  @spec handle(term(), term()) :: :kernel_default
  def handle(_event, _context), do: :kernel_default
end
