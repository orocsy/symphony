defmodule SymphonyElixir.Extensions.Noop.DeliveryObserver do
  @moduledoc "Neutral observer adapter with no side effects."

  @behaviour SymphonyElixir.Extensions.DeliveryObserver

  @impl true
  @spec record(term()) :: :ok
  def record(_event), do: :ok
end
