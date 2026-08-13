defmodule SymphonyElixir.Extensions.DeliveryController do
  @moduledoc "Adapter contract for delivery lifecycle decisions."

  alias SymphonyElixir.Extensions.ControllerFailure

  @type event :: term()
  @type decision :: term()
  @type result ::
          :kernel_default
          | {:ok, decision(), [event()]}
          | {:error, ControllerFailure.t(), [event()]}

  @callback handle(event(), term()) :: result()
end
