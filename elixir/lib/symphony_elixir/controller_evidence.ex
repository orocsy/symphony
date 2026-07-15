defmodule SymphonyElixir.ControllerEvidence do
  @moduledoc """
  Signs and verifies authority-bearing runtime controller evidence.

  Worker-authored request events remain unsigned inputs. Certificates and
  terminal controller outcomes require an HMAC key that is not stored in the
  issue workspace.
  """

  @signature_field "controller_signature"
  @default_key_path ".config/orocsy-symphony/controller-evidence.key"

  @spec sign(map()) :: map()
  def sign(evidence) when is_map(evidence) do
    signature = evidence |> unsigned() |> signature()
    Map.put(evidence, @signature_field, signature)
  end

  @spec valid?(map()) :: boolean()
  def valid?(evidence) when is_map(evidence) do
    with signature when is_binary(signature) <- evidence[@signature_field],
         expected <- evidence |> unsigned() |> signature(),
         true <- byte_size(signature) == byte_size(expected) do
      Plug.Crypto.secure_compare(signature, expected)
    else
      _ -> false
    end
  rescue
    _error -> false
  end

  def valid?(_evidence), do: false

  @spec key_path() :: String.t()
  def key_path do
    System.get_env("SYMPHONY_CONTROLLER_EVIDENCE_KEY_PATH") ||
      Path.join(System.user_home!(), @default_key_path)
  end

  defp unsigned(evidence), do: Map.delete(evidence, @signature_field)

  defp signature(evidence) do
    :crypto.mac(:hmac, :sha256, signing_key(), canonical_json(evidence))
    |> Base.encode16(case: :lower)
    |> then(&("hmac-sha256:" <> &1))
  end

  defp signing_key do
    case Application.get_env(:symphony_elixir, :controller_evidence_signing_key) do
      key when is_binary(key) and byte_size(key) >= 32 -> key
      _ -> persistent_signing_key()
    end
  end

  defp persistent_signing_key do
    path = key_path()

    case File.read(path) do
      {:ok, encoded} -> decode_key!(encoded, path)
      {:error, :enoent} -> create_key(path)
      {:error, reason} -> raise "cannot read controller evidence key #{path}: #{inspect(reason)}"
    end
  end

  defp create_key(path) do
    key = :crypto.strong_rand_bytes(32)
    encoded = Base.encode64(key) <> "\n"
    File.mkdir_p!(Path.dirname(path))

    case File.write(path, encoded, [:exclusive]) do
      :ok ->
        :ok = File.chmod(path, 0o600)
        key

      {:error, :eexist} ->
        path |> File.read!() |> decode_key!(path)

      {:error, reason} ->
        raise "cannot create controller evidence key #{path}: #{inspect(reason)}"
    end
  end

  defp decode_key!(encoded, path) do
    case Base.decode64(String.trim(encoded)) do
      {:ok, key} when byte_size(key) >= 32 -> key
      _ -> raise "invalid controller evidence key at #{path}"
    end
  end

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join(",", fn {key, nested} ->
      Jason.encode!(to_string(key)) <> ":" <> canonical_json(nested)
    end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp canonical_json(value) when is_list(value), do: "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"
  defp canonical_json(value), do: Jason.encode!(value)
end
