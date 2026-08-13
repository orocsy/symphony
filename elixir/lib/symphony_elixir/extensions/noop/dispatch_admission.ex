defmodule SymphonyElixir.Extensions.Noop.DispatchAdmission do
  @moduledoc "Neutral admission adapter that preserves the kernel path."

  @behaviour SymphonyElixir.Extensions.DispatchAdmission

  @impl true
  @spec evaluate(term(), term()) :: :kernel_default
  def evaluate(_issue, _context), do: :kernel_default
end
