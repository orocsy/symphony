defmodule SymphonyElixir.Extensions.Noop.DispatchAdmission do
  @moduledoc "Neutral admission adapter that preserves the kernel path."

  @behaviour SymphonyElixir.Extensions.DispatchAdmission

  alias SymphonyElixir.Extensions.AdmissionContext
  alias SymphonyElixir.Tracker.Issue

  @impl true
  @spec evaluate(Issue.t(), AdmissionContext.t()) :: :kernel_default
  def evaluate(%Issue{}, %AdmissionContext{}), do: :kernel_default
end
