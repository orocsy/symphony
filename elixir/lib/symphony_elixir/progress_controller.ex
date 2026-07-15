defmodule SymphonyElixir.ProgressController do
  @moduledoc """
  Owns bounded no-progress recovery decisions.

  Telemetry supplies observations; this controller returns a decision without
  mutating workers, issues, corrections, or dashboards.
  """

  @stable_fingerprint_keys [
    :issue,
    :contract_hash,
    :head_sha,
    :tree_sha,
    :dirty_paths,
    :blocker_class,
    :command_fingerprint,
    "issue",
    "contract_hash",
    "head_sha",
    "tree_sha",
    "dirty_paths",
    "blocker_class",
    "command_fingerprint"
  ]

  @type decision ::
          {:recover_once, String.t()}
          | {:operator_required, String.t()}
          | {:block, String.t()}

  @spec decide(map()) :: decision()
  def decide(%{fingerprint: fingerprint, local_progress?: true, prior_recoveries: 0})
      when is_binary(fingerprint),
      do: {:recover_once, fingerprint}

  def decide(%{fingerprint: fingerprint, local_progress?: true, prior_recoveries: count})
      when is_binary(fingerprint) and is_integer(count) and count >= 1,
      do: {:operator_required, fingerprint}

  def decide(%{fingerprint: fingerprint}) when is_binary(fingerprint), do: {:block, fingerprint}
  def decide(_input), do: {:block, "sha256:invalid-progress-input"}

  @spec fingerprint(map()) :: String.t()
  def fingerprint(input) when is_map(input) do
    stable =
      input
      |> Map.take(@stable_fingerprint_keys)
      |> normalize_keys()
      |> Enum.sort()

    :crypto.hash(:sha256, :erlang.term_to_binary(stable))
    |> Base.encode16(case: :lower)
    |> then(&("sha256:" <> &1))
  end

  def fingerprint(_input), do: "sha256:invalid-progress-input"

  defp normalize_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp normalize_value(values) when is_list(values), do: Enum.sort(Enum.map(values, &to_string/1))
  defp normalize_value(value), do: value
end
