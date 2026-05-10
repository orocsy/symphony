defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    Workflow.current()
    |> prompt_template!()
    |> render_issue_template(issue, opts)
  end

  @spec render_issue_template(String.t(), SymphonyElixir.Linear.Issue.t() | map() | String.t() | nil, keyword()) ::
          String.t()
  def render_issue_template(template, issue_or_identifier, opts \\ []) when is_binary(template) do
    template = parse_template!(template)

    do_render_issue_template(template, issue_or_identifier, opts)
  end

  defp do_render_issue_template(template, issue_or_identifier, opts) do
    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue_or_identifier |> issue_template_context() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  defp issue_template_context(%_{} = issue), do: Map.from_struct(issue)

  defp issue_template_context(%{issue_identifier: identifier} = issue_context) do
    %{
      id: Map.get(issue_context, :issue_id),
      identifier: identifier
    }
  end

  defp issue_template_context(%{"issue_identifier" => identifier} = issue_context) do
    %{
      id: Map.get(issue_context, "issue_id"),
      identifier: identifier
    }
  end

  defp issue_template_context(identifier) when is_binary(identifier), do: %{id: nil, identifier: identifier}
  defp issue_template_context(_), do: %{id: nil, identifier: "issue"}

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
