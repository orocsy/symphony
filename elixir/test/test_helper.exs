ExUnit.start()
Application.put_env(:symphony_elixir, :controller_evidence_signing_key, String.duplicate("test-controller-key-", 2))
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
