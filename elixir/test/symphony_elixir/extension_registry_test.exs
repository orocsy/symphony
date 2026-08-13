defmodule SymphonyElixir.ExtensionRegistryTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ExtensionRegistry

  @interfaces [
    {SymphonyElixir.Extensions.DispatchAdmission, [evaluate: 2]},
    {SymphonyElixir.Extensions.DeliveryController, [handle: 2]},
    {SymphonyElixir.Extensions.CommandAuthorization, [authorize: 2]},
    {SymphonyElixir.Extensions.DeliveryObserver, [record: 1]}
  ]

  setup do
    reset_registry_if_available()
    on_exit(&reset_registry_if_available/0)
  end

  test "defaults an absent stanza to the closed no-op registry" do
    assert {:ok, registry, %{}} = resolve(%{})
    assert registry.schema_version == 1
    assert is_binary(registry.revision)
    assert String.starts_with?(registry.revision, "sha256:")
    assert registry.dispatch_admission == SymphonyElixir.Extensions.Noop.DispatchAdmission
    assert registry.delivery_controller == SymphonyElixir.Extensions.Noop.DeliveryController
    assert registry.command_authorization == SymphonyElixir.Extensions.Noop.CommandAuthorization
    assert registry.observers == [SymphonyElixir.Extensions.Noop.DeliveryObserver]
  end

  test "rejects unknown keys, invalid types, adapter names, and duplicate observers" do
    invalid = [
      {%{"extensions" => %{"unknown" => "noop"}}, :unknown_key},
      {%{"extensions" => []}, :invalid_type},
      {%{"extensions" => %{"delivery_controller" => 42}}, :invalid_type},
      {%{"extensions" => %{"observers" => "noop"}}, :invalid_type},
      {%{"extensions" => %{"observers" => ["noop", 42]}}, :invalid_type},
      {%{"extensions" => %{"options" => []}}, :invalid_type},
      {%{"extensions" => %{"dispatch_admission" => "not-installed"}}, :unknown_adapter},
      {%{"extensions" => %{"observers" => ["not-installed"]}}, :unknown_adapter},
      {%{"extensions" => %{"observers" => ["noop", "noop"]}}, :duplicate_observer}
    ]

    for {config, code} <- invalid do
      assert {:error, failure} = resolve(config)
      assert failure.code == code
      assert failure.interface in [nil, :dispatch_admission, :delivery_controller, :observers]
    end
  end

  test "never converts workflow strings into module atoms" do
    selector = "unknown-#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(selector) end

    assert {:error, failure} =
             resolve(%{"extensions" => %{"command_authorization" => selector}})

    assert failure.code == :unknown_adapter
    assert_raise ArgumentError, fn -> String.to_existing_atom(selector) end
  end

  test "locks adapter selection while returning new option snapshots" do
    first = fixture_config(%{"marker" => "first"})
    second = fixture_config(%{"marker" => "second"})

    assert {:ok, first_registry, %{"marker" => "first"}} = lock(first)
    assert {:ok, second_registry, %{"marker" => "second"}} = lock(second)
    assert first_registry.revision == second_registry.revision

    changed = put_in(second, ["extensions", "delivery_controller"], "noop")
    assert {:error, failure} = lock(changed)
    assert failure.code == :extension_registry_restart_required
    assert failure.interface == :delivery_controller

    ExtensionRegistry.reset_for_test()
    assert {:ok, _, _} = lock(first)

    observer_change = put_in(second, ["extensions", "observers"], ["noop"])
    assert {:error, observer_failure} = lock(observer_change)
    assert observer_failure.code == :extension_registry_restart_required
    assert observer_failure.interface == :observers
    assert observer_failure.adapter =~ "DeliveryObserver"
  end

  test "publishes the four exact adapter callback contracts" do
    for {interface, expected_callbacks} <- @interfaces do
      assert Code.ensure_loaded?(interface)
      assert interface.behaviour_info(:callbacks) == expected_callbacks
    end
  end

  defp resolve(config), do: ExtensionRegistry.resolve(config)
  defp lock(config), do: ExtensionRegistry.lock(config)

  defp fixture_config(options) do
    %{
      "extensions" => %{
        "dispatch_admission" => "fixture",
        "delivery_controller" => "fixture",
        "command_authorization" => "fixture",
        "observers" => ["fixture"],
        "options" => options
      }
    }
  end

  defp reset_registry_if_available do
    if Code.ensure_loaded?(ExtensionRegistry) and
         function_exported?(ExtensionRegistry, :reset_for_test, 0) do
      ExtensionRegistry.reset_for_test()
    else
      :ok
    end
  end
end
