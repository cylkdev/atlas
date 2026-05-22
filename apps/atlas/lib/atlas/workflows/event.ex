defmodule Atlas.Workflows.Event do
  @moduledoc """
  A workflow event. Just a `name` (list of string segments) and a
  `data` map. The name is the discriminator; subscribers match
  against it with pattern lists containing `"*"` wildcards.

  Name conventions:
    * step lifecycle:
        `["workflow", workflow_id, "step", step_id, lifecycle]`
        lifecycle ∈ `"started" | "finished" | "failed" | "skipped" |
                     "retrying" | "cancelled"`
    * terraform:
        `["workflow", workflow_id, "terraform", resource_type,
          lifecycle, resource_name]`
        lifecycle ∈ `"planned" | "creating" | "created" | "updating" |
                     "updated" | "destroying" | "destroyed" | "failed"`
    * terraform diagnostic:
        `["workflow", workflow_id, "terraform", "diagnostic", severity]`
        severity ∈ `"error" | "warning"`
    * ansible:
        `["workflow", workflow_id, "ansible", status, task_slug, host]`
        status ∈ `"started" | "ok" | "changed" | "failed" |
                  "skipped" | "unreachable"`
    * workflow:
        `["workflow", workflow_id, "finished"]`

  All event constructors are named functions on this module; there is
  no separate struct per event type. To create a new kind of event,
  add a named function here (or compose the name list in a provider).
  """

  @enforce_keys [:name, :data]
  defstruct [:name, :data]

  @type segment :: String.t()
  @type name :: [segment()]
  @type t :: %__MODULE__{name: name(), data: map()}

  @spec new(name(), map()) :: t()
  def new(name, data) when is_list(name) and is_map(data) do
    %__MODULE__{name: name, data: data}
  end

  # --- step lifecycle ---

  def step_started(workflow_id, step_id, attempt) do
    new(
      ["workflow", workflow_id, "step", step_id, "started"],
      %{attempt: attempt}
    )
  end

  def step_finished(workflow_id, step_id, output, attempts) do
    new(
      ["workflow", workflow_id, "step", step_id, "finished"],
      %{output: output, attempts: attempts}
    )
  end

  def step_failed(workflow_id, step_id, output, errors, attempts) do
    new(
      ["workflow", workflow_id, "step", step_id, "failed"],
      %{output: output, errors: errors, attempts: attempts}
    )
  end

  def step_skipped(workflow_id, step_id) do
    new(["workflow", workflow_id, "step", step_id, "skipped"], %{})
  end

  def step_retrying(workflow_id, step_id, attempt, next_attempt, output, delay_ms) do
    new(
      ["workflow", workflow_id, "step", step_id, "retrying"],
      %{attempt: attempt, next_attempt: next_attempt, output: output, delay_ms: delay_ms}
    )
  end

  def step_cancelled(workflow_id, step_id) do
    new(["workflow", workflow_id, "step", step_id, "cancelled"], %{})
  end

  # --- workflow lifecycle ---

  def workflow_finished(workflow_id, status) do
    new(["workflow", workflow_id, "finished"], %{status: status})
  end

  # --- terraform ---

  @doc """
  Build a terraform resource lifecycle event.

  `lifecycle` is one of: `:planned`, `:creating`, `:created`,
  `:updating`, `:updated`, `:destroying`, `:destroyed`, `:failed`
  (encoded as its string form in the name). `resource_name` may be
  `nil`; if so, the segment becomes `"_"`. `extras` is merged into
  the data map.
  """
  def terraform_resource(workflow_id, resource_type, lifecycle, resource_name, extras \\ %{}) do
    name = [
      "workflow",
      workflow_id,
      "terraform",
      resource_type,
      Atom.to_string(lifecycle),
      name_seg(resource_name)
    ]

    data =
      Map.merge(extras, %{
        resource_type: resource_type,
        lifecycle: lifecycle,
        resource_name: resource_name
      })

    new(name, data)
  end

  @doc """
  Build a terraform diagnostic event.

  `severity` is `:error` or `:warning` (encoded as its string form
  in the name). `payload` carries at minimum `:summary` and `:detail`;
  callers typically also include `:address`, `:filename`, `:line`,
  and `:raw`.
  """
  def terraform_diagnostic(workflow_id, severity, payload) when is_map(payload) do
    new(
      ["workflow", workflow_id, "terraform", "diagnostic", Atom.to_string(severity)],
      Map.put(payload, :severity, severity)
    )
  end

  # --- ansible ---

  @doc """
  Build an ansible task event.

  `status` is one of: `:started`, `:ok`, `:changed`, `:failed`,
  `:skipped`, `:unreachable`. `task` is normalized into a name
  segment (lowercased, non-`[a-z0-9_-]` runs replaced with `_`).
  """
  def ansible_task(workflow_id, status, task, host, extras \\ %{}) do
    name = [
      "workflow",
      workflow_id,
      "ansible",
      Atom.to_string(status),
      slugify(task),
      name_seg(host)
    ]

    data = Map.merge(extras, %{status: status, task: task, host: host})

    new(name, data)
  end

  defp name_seg(nil), do: "_"
  defp name_seg(value) when is_binary(value), do: value

  defp slugify(nil), do: "_"

  defp slugify(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "_"
      slug -> slug
    end
  end
end
