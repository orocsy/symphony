defmodule SymphonyElixir.Extensions.DeliveryObserver do
  @moduledoc "Observer-only adapter contract with no control return path."

  alias SymphonyElixir.Extensions.ObserverFailure

  @callback record(term()) :: :ok | {:error, ObserverFailure.t()}
end
