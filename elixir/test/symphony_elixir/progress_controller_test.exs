defmodule SymphonyElixir.ProgressControllerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ProgressController

  test "permits one preserved-workspace recovery and then requires an operator" do
    input = %{fingerprint: "sha256:same", local_progress?: true, prior_recoveries: 0}
    assert {:recover_once, "sha256:same"} = ProgressController.decide(input)

    assert {:operator_required, "sha256:same"} =
             ProgressController.decide(%{input | prior_recoveries: 1})
  end

  test "does not recover no-progress runs without local handoff progress" do
    assert {:block, "sha256:none"} =
             ProgressController.decide(%{
               fingerprint: "sha256:none",
               local_progress?: false,
               prior_recoveries: 0
             })
  end

  test "fingerprint excludes incidental timestamps and token totals" do
    stable = %{
      issue: "COD-266",
      contract_hash: "sha256:contract",
      head_sha: "abc",
      tree_sha: "tree",
      dirty_paths: ["src/app/api/cards/handler.ts"],
      blocker_class: "no-durable-progress",
      command_fingerprint: "command"
    }

    assert ProgressController.fingerprint(Map.put(stable, :observed_at, "first")) ==
             ProgressController.fingerprint(Map.put(stable, :observed_at, "second"))

    assert ProgressController.fingerprint(Map.put(stable, :total_tokens, 10)) ==
             ProgressController.fingerprint(Map.put(stable, :total_tokens, 99_999))
  end
end
