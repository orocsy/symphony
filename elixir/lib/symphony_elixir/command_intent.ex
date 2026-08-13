defmodule SymphonyElixir.CommandIntent do
  @moduledoc """
  Classifies supported worker commands by their observable intent.

  This is a workflow guard, not a shell sandbox. Unknown or composed commands
  remain conservative at the policy layer.
  """

  @type intent :: %{
          required(:kind) => :scope_audit | :content_diff | :other,
          optional(:output) => :names_only,
          optional(:base_ref) => String.t(),
          optional(:head_ref) => String.t(),
          optional(:reason) => atom()
        }

  @spec classify(String.t()) :: {:ok, intent()} | {:error, atom()}
  def classify(command), do: classify(command, [])

  @spec classify(String.t(), keyword()) :: {:ok, intent()} | {:error, atom()}
  def classify(command, opts) when is_binary(command) do
    command = unwrap_shell(command)

    if shell_composition?(command) do
      {:error, :shell_composition}
    else
      classify_tokens(OptionParser.split(command), opts)
    end
  rescue
    _error -> {:error, :unparseable_command}
  end

  def classify(_command, _opts), do: {:error, :unparseable_command}

  defp classify_tokens(["git", "diff" | args], opts), do: classify_git_diff(args, opts)
  defp classify_tokens(_tokens, _opts), do: {:ok, %{kind: :other}}

  defp classify_git_diff(args, opts) do
    allowed_base_refs = Keyword.get(opts, :allowed_base_refs, []) |> MapSet.new()
    range = Enum.find(args, &triple_dot_range?/1)
    {base_ref, head_ref} = split_range(range)

    cond do
      not names_only?(args) ->
        {:ok, %{kind: :content_diff, reason: :content_output}}

      content_or_unknown_flag?(args) ->
        {:ok, %{kind: :content_diff, reason: :content_or_unknown_flag}}

      is_nil(range) ->
        {:ok, %{kind: :content_diff, reason: :missing_base_range}}

      not MapSet.member?(allowed_base_refs, base_ref) ->
        {:ok, %{kind: :content_diff, reason: :undeclared_base_ref}}

      head_ref != "HEAD" ->
        {:ok, %{kind: :content_diff, reason: :undeclared_head_ref}}

      positional_args(args) != [range] ->
        {:ok, %{kind: :content_diff, reason: :unexpected_path_scope}}

      true ->
        {:ok,
         %{
           kind: :scope_audit,
           output: :names_only,
           base_ref: base_ref,
           head_ref: head_ref
         }}
    end
  end

  defp names_only?(args), do: "--name-only" in args

  defp content_or_unknown_flag?(args) do
    Enum.any?(args, fn arg ->
      String.starts_with?(arg, "-") and not metadata_flag?(arg)
    end)
  end

  defp metadata_flag?("--name-only"), do: true
  defp metadata_flag?("--no-renames"), do: true
  defp metadata_flag?("--relative"), do: true
  defp metadata_flag?("--"), do: true
  defp metadata_flag?("--diff-filter=" <> value), do: Regex.match?(~r/^[ACDMRTUXB*]+$/, value)
  defp metadata_flag?(_arg), do: false

  defp positional_args(args) do
    Enum.reject(args, &String.starts_with?(&1, "-"))
  end

  defp triple_dot_range?(arg) when is_binary(arg) do
    case String.split(arg, "...", parts: 2) do
      [left, right] -> left != "" and right != ""
      _ -> false
    end
  end

  defp triple_dot_range?(_arg), do: false

  defp split_range(nil), do: {nil, nil}

  defp split_range(range) do
    case String.split(range, "...", parts: 2) do
      [base_ref, head_ref] -> {base_ref, head_ref}
      _ -> {nil, nil}
    end
  end

  defp unwrap_shell(command) do
    case OptionParser.split(command) do
      [shell, "-lc", inner] when shell in ["zsh", "bash", "sh", "/bin/zsh", "/bin/bash", "/bin/sh"] -> inner
      _ -> String.trim(command)
    end
  end

  defp shell_composition?(command) do
    command
    |> String.graphemes()
    |> scan_composition(nil, nil)
  end

  defp scan_composition([], _quote, _previous), do: false

  defp scan_composition(["\\" | [_escaped | rest]], quote, _previous) do
    scan_composition(rest, quote, "\\")
  end

  defp scan_composition([char | rest], nil, previous) when char in ["'", "\""] do
    scan_composition(rest, char, previous)
  end

  defp scan_composition([char | rest], quote, previous) when char == quote do
    scan_composition(rest, nil, previous)
  end

  defp scan_composition([char | rest], nil, previous) do
    next = List.first(rest)

    cond do
      char == ";" -> true
      char == "|" and previous not in ["|", "\\"] -> true
      char == "&" and next == "&" -> true
      char == "$" and next == "(" -> true
      char in [">", "<"] -> true
      true -> scan_composition(rest, nil, char)
    end
  end

  defp scan_composition([char | rest], quote, _previous), do: scan_composition(rest, quote, char)
end
