defmodule SymphonyElixir.Extensions.Noop.DeliveryController do
  @moduledoc "Neutral delivery adapter that preserves the kernel path."

  @behaviour SymphonyElixir.Extensions.DeliveryController

  alias SymphonyElixir.Extensions.DeliveryContext
  alias SymphonyElixir.Extensions.DeliveryEvent

  @impl true
  @spec handle(DeliveryEvent.t(), DeliveryContext.t()) :: :kernel_default
  def handle(%DeliveryEvent{}, %DeliveryContext{}), do: :kernel_default
end
