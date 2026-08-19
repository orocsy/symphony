import Config

config :phoenix, :json_library, Jason

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false

if config_env() == :test do
  config :symphony_elixir,
    workflow_file_path: Path.expand("../test/fixtures/startup_workflow.md", __DIR__),
    extension_registry_test_reset: true,
    extension_adapter_catalog: %{
      dispatch_admission: %{
        "noop" => SymphonyElixir.Extensions.Noop.DispatchAdmission,
        "fixture" => SymphonyElixir.ExtensionHostFixtures.DispatchAdmission,
        "lifecycle_fixture" => SymphonyElixir.ExtensionLifecycleFixtures.DispatchAdmission
      },
      delivery_controller: %{
        "noop" => SymphonyElixir.Extensions.Noop.DeliveryController,
        "fixture" => SymphonyElixir.ExtensionHostFixtures.DeliveryController,
        "lifecycle_fixture" => SymphonyElixir.ExtensionLifecycleFixtures.DeliveryController
      },
      command_authorization: %{
        "noop" => SymphonyElixir.Extensions.Noop.CommandAuthorization,
        "fixture" => SymphonyElixir.ExtensionHostFixtures.CommandAuthorization,
        "turn_fixture" => SymphonyElixir.ExtensionTurnFixtures.CommandAuthorization
      },
      observers: %{
        "noop" => SymphonyElixir.Extensions.Noop.DeliveryObserver,
        "fixture" => SymphonyElixir.ExtensionHostFixtures.DeliveryObserver,
        "raising" => SymphonyElixir.ExtensionHostFixtures.RaisingObserver,
        "observer_fixture" => SymphonyElixir.ExtensionObserverFixtures.Observer,
        "observer_hanging" => SymphonyElixir.ExtensionObserverFixtures.HangingObserver,
        "observer_error" => SymphonyElixir.ExtensionObserverFixtures.ErrorObserver,
        "observer_wrong_interface" => SymphonyElixir.ExtensionObserverFixtures.WrongInterfaceObserver,
        "observer_malformed" => SymphonyElixir.ExtensionObserverFixtures.MalformedObserver,
        "observer_throwing" => SymphonyElixir.ExtensionObserverFixtures.ThrowingObserver,
        "observer_exiting" => SymphonyElixir.ExtensionObserverFixtures.ExitingObserver,
        "observer_killing" => SymphonyElixir.ExtensionObserverFixtures.KillingObserver
      }
    }
end
