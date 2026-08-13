defmodule SymphonyElixir.ExtensionRegistry do
  @moduledoc """
  Resolves the closed extension catalog and latches adapter selection for the
  lifetime of the BEAM.
  """

  alias SymphonyElixir.Extensions.ExtensionFailure

  @schema_version 1
  @runtime_key {__MODULE__, :runtime_registry}
  @selector_keys [
    "dispatch_admission",
    "delivery_controller",
    "command_authorization",
    "observers"
  ]
  @allowed_keys @selector_keys ++ ["options"]
  @production_catalog %{
    dispatch_admission: %{
      "noop" => SymphonyElixir.Extensions.Noop.DispatchAdmission
    },
    delivery_controller: %{
      "noop" => SymphonyElixir.Extensions.Noop.DeliveryController
    },
    command_authorization: %{
      "noop" => SymphonyElixir.Extensions.Noop.CommandAuthorization
    },
    observers: %{
      "noop" => SymphonyElixir.Extensions.Noop.DeliveryObserver
    }
  }
  @catalog Application.compile_env(
             :symphony_elixir,
             :extension_adapter_catalog,
             @production_catalog
           )
  @test_reset? Application.compile_env(
                 :symphony_elixir,
                 :extension_registry_test_reset,
                 false
               )

  @enforce_keys [
    :schema_version,
    :revision,
    :dispatch_admission,
    :delivery_controller,
    :command_authorization,
    :observers
  ]
  defstruct [
    :schema_version,
    :revision,
    :dispatch_admission,
    :delivery_controller,
    :command_authorization,
    observers: []
  ]

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          revision: String.t(),
          dispatch_admission: module(),
          delivery_controller: module(),
          command_authorization: module(),
          observers: [module()]
        }

  @type resolution :: {:ok, t(), map()} | {:error, ExtensionFailure.t()}

  @spec resolve(map()) :: resolution()
  def resolve(config) when is_map(config) do
    with {:ok, extension_config} <- extension_config(config),
         :ok <- validate_keys(extension_config),
         {:ok, selectors} <- selectors(extension_config),
         {:ok, options} <- options(extension_config),
         {:ok, adapters} <- resolve_adapters(selectors) do
      {:ok, build_registry(adapters), options}
    end
  end

  @spec lock(map()) :: resolution()
  def lock(config) when is_map(config) do
    with {:ok, requested, options} <- resolve(config) do
      case :persistent_term.get(@runtime_key, :unlocked) do
        :unlocked ->
          :persistent_term.put(@runtime_key, requested)
          {:ok, requested, options}

        %__MODULE__{} = locked ->
          compare_locked(locked, requested, options)
      end
    end
  end

  @spec current() :: {:ok, t()} | {:error, ExtensionFailure.t()}
  def current do
    case :persistent_term.get(@runtime_key, :unlocked) do
      %__MODULE__{} = registry ->
        {:ok, registry}

      :unlocked ->
        {:error, failure(:extension_registry_unavailable, nil, nil, nil, :admission_not_evaluated)}
    end
  end

  if @test_reset? do
    @doc false
    @spec reset_for_test() :: :ok
    def reset_for_test do
      _ = :persistent_term.erase(@runtime_key)
      :ok
    end
  end

  defp extension_config(config) do
    case Map.get(config, "extensions", :absent) do
      :absent -> {:ok, %{}}
      extension_config when is_map(extension_config) -> {:ok, extension_config}
      _other -> {:error, failure(:invalid_type, nil, nil, nil, :extensions_must_be_map)}
    end
  end

  defp validate_keys(extension_config) do
    case Enum.find(Map.keys(extension_config), &(&1 not in @allowed_keys)) do
      nil -> :ok
      key -> {:error, failure(:unknown_key, nil, nil, nil, %{key: key})}
    end
  end

  defp selectors(extension_config) do
    selectors = %{
      dispatch_admission: Map.get(extension_config, "dispatch_admission", "noop"),
      delivery_controller: Map.get(extension_config, "delivery_controller", "noop"),
      command_authorization: Map.get(extension_config, "command_authorization", "noop"),
      observers: Map.get(extension_config, "observers", ["noop"])
    }

    with :ok <- validate_selector(selectors.dispatch_admission, :dispatch_admission),
         :ok <- validate_selector(selectors.delivery_controller, :delivery_controller),
         :ok <- validate_selector(selectors.command_authorization, :command_authorization),
         :ok <- validate_observers(selectors.observers) do
      {:ok, selectors}
    end
  end

  defp validate_selector(selector, _interface) when is_binary(selector), do: :ok

  defp validate_selector(_selector, interface) do
    {:error, failure(:invalid_type, interface, nil, nil, :selector_must_be_string)}
  end

  defp validate_observers(observers) when is_list(observers) do
    cond do
      !Enum.all?(observers, &is_binary/1) ->
        {:error, failure(:invalid_type, :observers, nil, nil, :observers_must_be_strings)}

      Enum.uniq(observers) != observers ->
        {:error, failure(:duplicate_observer, :observers, nil, nil, :observer_names_must_be_unique)}

      true ->
        :ok
    end
  end

  defp validate_observers(_observers) do
    {:error, failure(:invalid_type, :observers, nil, nil, :observers_must_be_list)}
  end

  defp options(extension_config) do
    case Map.get(extension_config, "options", %{}) do
      options when is_map(options) -> {:ok, options}
      _other -> {:error, failure(:invalid_type, nil, nil, nil, :options_must_be_map)}
    end
  end

  defp resolve_adapters(selectors) do
    with {:ok, dispatch_admission} <-
           resolve_adapter(:dispatch_admission, selectors.dispatch_admission),
         {:ok, delivery_controller} <-
           resolve_adapter(:delivery_controller, selectors.delivery_controller),
         {:ok, command_authorization} <-
           resolve_adapter(:command_authorization, selectors.command_authorization),
         {:ok, observers} <- resolve_observers(selectors.observers) do
      {:ok,
       %{
         dispatch_admission: dispatch_admission,
         delivery_controller: delivery_controller,
         command_authorization: command_authorization,
         observers: observers
       }}
    end
  end

  defp resolve_observers(selectors) do
    Enum.reduce_while(selectors, {:ok, []}, fn selector, {:ok, modules} ->
      case resolve_adapter(:observers, selector) do
        {:ok, module} -> {:cont, {:ok, [module | modules]}}
        {:error, _failure} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, modules} -> {:ok, Enum.reverse(modules)}
      {:error, _failure} = error -> error
    end
  end

  defp resolve_adapter(interface, selector) do
    case get_in(@catalog, [interface, selector]) do
      module when is_atom(module) and not is_nil(module) ->
        {:ok, module}

      _other ->
        {:error, failure(:unknown_adapter, interface, nil, nil, :selector_not_in_catalog)}
    end
  end

  defp build_registry(adapters) do
    selection = [
      {:schema_version, @schema_version},
      {:dispatch_admission, adapters.dispatch_admission},
      {:delivery_controller, adapters.delivery_controller},
      {:command_authorization, adapters.command_authorization},
      {:observers, adapters.observers}
    ]

    revision =
      selection
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> then(&("sha256:" <> &1))

    struct!(__MODULE__, Map.merge(adapters, %{schema_version: @schema_version, revision: revision}))
  end

  defp compare_locked(locked, requested, options) do
    case changed_interface(locked, requested) do
      nil ->
        {:ok, locked, options}

      interface ->
        {:error,
         failure(
           :extension_registry_restart_required,
           interface,
           requested_adapter(requested, interface),
           locked.revision,
           :adapter_selection_changed
         )}
    end
  end

  defp changed_interface(locked, requested) do
    Enum.find(
      [:dispatch_admission, :delivery_controller, :command_authorization, :observers],
      &(Map.fetch!(locked, &1) != Map.fetch!(requested, &1))
    )
  end

  defp requested_adapter(registry, :observers), do: inspect(registry.observers)
  defp requested_adapter(registry, interface), do: Map.fetch!(registry, interface)

  defp failure(code, interface, adapter, revision, reason) do
    %ExtensionFailure{
      code: code,
      interface: interface,
      adapter: adapter,
      registry_revision: revision,
      reason: reason
    }
  end
end
