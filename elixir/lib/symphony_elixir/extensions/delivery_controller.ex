defmodule SymphonyElixir.Extensions.DeliveryController do
  @moduledoc "Adapter contract for delivery lifecycle decisions."

  alias SymphonyElixir.Extensions.ControllerFailure
  alias SymphonyElixir.Extensions.DeliveryContext
  alias SymphonyElixir.Extensions.DeliveryEvent

  @type decision :: term()
  @type emitted_event :: term()
  @type result ::
          :kernel_default
          | {:ok, decision(), [emitted_event()]}
          | {:error, ControllerFailure.t(), [emitted_event()]}

  @callback handle(DeliveryEvent.t(), DeliveryContext.t()) :: result()
end
