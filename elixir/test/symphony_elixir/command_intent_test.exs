defmodule SymphonyElixir.CommandIntentTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CommandIntent

  test "classifies a strict names-only base diff as a scope audit" do
    assert {:ok, intent} =
             CommandIntent.classify(
               "git diff --name-only --no-renames origin/main...HEAD",
               allowed_base_refs: ["main", "origin/main"]
             )

    assert intent.kind == :scope_audit
    assert intent.output == :names_only
    assert intent.base_ref == "origin/main"
    assert intent.head_ref == "HEAD"
  end

  test "keeps patch-producing and undeclared-ref diffs out of scope audit" do
    assert {:ok, %{kind: :content_diff}} =
             CommandIntent.classify(
               "git diff --name-only --patch origin/main...HEAD",
               allowed_base_refs: ["origin/main"]
             )

    assert {:ok, %{kind: :content_diff, reason: :undeclared_base_ref}} =
             CommandIntent.classify(
               "git diff --name-only --no-renames origin/other...HEAD",
               allowed_base_refs: ["origin/main"]
             )
  end

  test "rejects shell composition before classifying git intent" do
    assert {:error, :shell_composition} =
             CommandIntent.classify(
               "git diff --name-only origin/main...HEAD | xargs cat",
               allowed_base_refs: ["origin/main"]
             )
  end
end
