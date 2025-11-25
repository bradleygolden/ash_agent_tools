defmodule AshAgentTools.Tools.AshAction do
  @moduledoc """
  Tool implementation for executing Ash actions.
  """

  @behaviour AshAgentTools.Tool

  alias Ash.Resource.Info

  defstruct [:name, :description, :resource, :action_name]

  def new(opts) do
    %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      description: Keyword.fetch!(opts, :description),
      resource: Keyword.fetch!(opts, :resource),
      action_name: Keyword.fetch!(opts, :action_name)
    }
  end

  def to_schema(%__MODULE__{} = tool) do
    %{
      "name" => to_string(tool.name),
      "description" => tool.description || "",
      "parameters" => %{
        "type" => "object",
        "properties" => %{},
        "required" => []
      }
    }
  end

  @impl true
  def name, do: :ash_action

  @impl true
  def description, do: "Executes an Ash action"

  @impl true
  def schema do
    %{
      name: "ash_action",
      description: "Executes an Ash action",
      parameters: %{
        type: :object,
        properties: %{},
        required: []
      }
    }
  end

  @impl true
  def execute(args, context) do
    tool = context.tool
    call_ash_action(tool, args, context)
  end

  defp call_ash_action(tool, args, context) do
    opts = [
      actor: context[:actor],
      tenant: context[:tenant]
    ]

    action = Info.action(tool.resource, tool.action_name)

    result =
      case action.type do
        :read ->
          tool.resource
          |> Ash.Query.for_read(tool.action_name, args, opts)
          |> Ash.read()

        :create ->
          tool.resource
          |> Ash.Changeset.for_create(tool.action_name, args, opts)
          |> Ash.create()

        :update ->
          record = context[:record] || get_record_for_update(tool, args, opts)

          record
          |> Ash.Changeset.for_update(tool.action_name, args, opts)
          |> Ash.update()

        :destroy ->
          record = context[:record] || get_record_for_destroy(tool, args, opts)

          record
          |> Ash.Changeset.for_destroy(tool.action_name, args, opts)
          |> Ash.destroy()
      end

    case result do
      {:ok, record} -> {:ok, normalize_ash_result(record)}
      {:error, error} -> {:error, format_ash_error(error)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp get_record_for_update(tool, args, opts) do
    id = args[:id] || args["id"]

    case Ash.get(tool.resource, id, opts) do
      {:ok, record} -> record
      {:error, _} -> raise "Record not found for update"
    end
  end

  defp get_record_for_destroy(tool, args, opts) do
    id = args[:id] || args["id"]

    case Ash.get(tool.resource, id, opts) do
      {:ok, record} -> record
      {:error, _} -> raise "Record not found for destroy"
    end
  end

  defp normalize_ash_result(%Ash.BulkResult{} = bulk_result) do
    %{
      records: bulk_result.records,
      count: length(bulk_result.records),
      errors: bulk_result.errors
    }
  end

  defp normalize_ash_result(%Ash.Page.Offset{} = page) do
    %{
      results: page.results,
      count: page.count,
      more?: page.more?
    }
  end

  defp normalize_ash_result(%Ash.Page.Keyset{} = page) do
    %{
      results: page.results,
      more?: page.more?,
      before: page.before,
      after: page.after
    }
  end

  defp normalize_ash_result(result) when is_struct(result) do
    result
    |> Map.from_struct()
    |> Map.drop([:__meta__, :__metadata__, :aggregates, :calculations])
  end

  defp normalize_ash_result(result), do: result

  defp format_ash_error(%Ash.Error.Invalid{errors: errors}) do
    Enum.map_join(errors, ", ", &format_single_error/1)
  end

  defp format_ash_error(error), do: inspect(error)

  defp format_single_error(%{field: field, message: message}) do
    "#{field}: #{message}"
  end
end
