defmodule Atlas.Workflows.Event.Pattern do
  @moduledoc """
  Compile and match list-of-segments event-name patterns.

  Convention:
    * Names are lists of string segments.
    * Patterns are also lists of string segments. The string `"*"` is
      the wildcard; it matches one or more name segments.
    * Patterns supplied by callers are **relative** — they do not
      include the `["workflow", workflow_id]` prefix. `compile/2`
      prepends that prefix so the compiled pattern matches full
      names on the wire.
    * Matching is a direct recursive walk over two lists — no
      regex, no string splitting.

  Examples (after compile with workflow_id `"wf-1"`):
    * `["*"]`                                      → `["workflow", "wf-1", "*"]`
    * `["terraform", "*"]`                         → `["workflow", "wf-1", "terraform", "*"]`
    * `["terraform", "*", "created", "*"]`         → `["workflow", "wf-1", "terraform", "*", "created", "*"]`
    * `["terraform", "aws_asg", "created", "web"]` → `["workflow", "wf-1", "terraform", "aws_asg", "created", "web"]`
  """

  @type pattern :: [String.t()]

  @spec compile(pattern(), String.t()) :: pattern()
  def compile(relative_pattern, workflow_id)
      when is_list(relative_pattern) and is_binary(workflow_id) do
    ["workflow", workflow_id | relative_pattern]
  end

  @spec matches?(pattern(), [String.t()]) :: boolean()
  def matches?(pattern, name) when is_list(pattern) and is_list(name) do
    do_match(pattern, name)
  end

  defp do_match([], []), do: true
  defp do_match([], _), do: false
  defp do_match(_, []), do: false

  defp do_match(["*" | rest_pat], [_ | rest_name]) do
    # "*" matches one or more segments; try one then backtrack to more.
    do_match(rest_pat, rest_name) or do_match(["*" | rest_pat], rest_name)
  end

  defp do_match([seg | rest_pat], [seg | rest_name]) do
    do_match(rest_pat, rest_name)
  end

  defp do_match(_, _), do: false
end
