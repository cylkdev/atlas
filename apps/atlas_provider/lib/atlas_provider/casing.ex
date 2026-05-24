defmodule AtlasProvider.Casing do
  @moduledoc """
  A configurable adapter for converting strings between casing styles.

  Wraps an underlying casing library (default: [`Recase`](https://hexdocs.pm/recase))
  behind a single `to_case/3` entrypoint. Callers pick the casing by atom and
  the adapter routes the call to the right function on the configured backend,
  validating that the function actually exists before invoking it.

  The backend is pluggable: it may be a module atom, a `{module, function}`
  tuple, or an inline 1- or 2-arity function. This lets a project swap in a
  custom casing implementation without changing call sites.

  ## Responsibilities

    - Convert a value to one of the supported casings: `:camel`, `:constant`,
      `:dot`, `:header`, `:kebab`, `:name`, `:pascal`, `:path`, `:sentence`,
      `:snake` (default), `:title`, `:underscore`.
    - Resolve the backend from `opts[:casing_module]`, falling back to
      `Recase`.
    - Raise `ArgumentError` when the requested casing is unsupported, the
      backend does not export the required function, or the backend value is
      not a recognised shape.

  ## Examples

      iex> AtlasProvider.Casing.to_case("HelloWorld")
      "hello_world"

      iex> AtlasProvider.Casing.to_case("hello_world", :camel)
      "helloWorld"

      iex> AtlasProvider.Casing.to_case("HelloWorld", :kebab)
      "hello-world"

  """

  # Abstraction Function:
  #   The module represents a stateless dispatcher: a partial function
  #   `(value, casing, backend) -> recased_value` that resolves `backend`
  #   from `opts[:casing_module]` (or `@default_casing_module` when absent)
  #   and routes `casing` to the corresponding function on `backend`.
  #   `@default_casing_module` represents the implicit backend used when
  #   no override is supplied. `@default_casing` represents the implicit
  #   casing used when the caller passes `nil` (or omits the argument).
  #   `@supported_casings` enumerates the casings the module agrees to
  #   accept on the module-atom dispatch path.
  #
  # Data Invariant:
  #   1. `casing_module!/1` returns a non-`nil` value: either
  #      `opts[:casing_module]` (when present) or `@default_casing_module`.
  #   2. On the module-atom dispatch path, the requested casing must be a
  #      member of `@supported_casings`; any other atom raises
  #      `ArgumentError` with a message listing the supported casings.
  #   3. On the module-atom dispatch path, the chosen backend must export
  #      the casing's expected `to_<casing>/1` function (or `underscore/1`
  #      for `:underscore`); otherwise `ArgumentError` is raised.
  #   4. On the `{module, function}` dispatch path, the named function
  #      must be exported with arity 2; otherwise `ArgumentError` is
  #      raised.
  #   5. On the inline-function dispatch path, the function's arity must
  #      be 1 or 2; any other arity raises `ArgumentError`.
  #   6. A backend value that is not an atom, a function, or a
  #      `{module, function}` tuple raises `ArgumentError`.
  #
  # Commutative Diagram (to_case dispatch):
  #
  #   (term, casing, opts)  --to_case-->  recased_term
  #          |                                ^
  #          | casing_module!(opts)           |
  #          v                                |
  #     resolved_backend --apply_casing-------+

  @default_casing_module Recase
  @default_casing :snake

  @doc """
  Converts an atom or string to camel case.
  """
  def to_camel(term, opts \\ []) do
    to_case(term, :camel, opts)
  end

  @doc """
  Converts an atom or string to constant case.
  """
  def to_constant(term, opts \\ []) do
    to_case(term, :constant, opts)
  end

  @doc """
  Converts an atom or string to dot case.
  """
  def to_dot(term, opts \\ []) do
    to_case(term, :dot, opts)
  end

  @doc """
  Converts an atom or string to header case.
  """
  def to_header(term, opts \\ []) do
    to_case(term, :header, opts)
  end

  @doc """
  Converts an atom or string to kebab case.
  """
  def to_kebab(term, opts \\ []) do
    to_case(term, :kebab, opts)
  end

  @doc """
  Converts an atom or string to name case.
  """
  def to_name(term, opts \\ []) do
    to_case(term, :name, opts)
  end

  @doc """
  Converts an atom or string to pascal case.
  """
  def to_pascal(term, opts \\ []) do
    to_case(term, :pascal, opts)
  end

  @doc """
  Converts an atom or string to path case.
  """
  def to_path(term, opts \\ []) do
    to_case(term, :path, opts)
  end

  @doc """
  Converts an atom or string to sentence case.
  """
  def to_sentence(term, opts \\ []) do
    to_case(term, :sentence, opts)
  end

  @doc """
  Converts an atom or string to snake case.
  """
  def to_snake(term, opts \\ []) do
    to_case(term, :snake, opts)
  end

  @doc """
  Converts an atom or string to title case.
  """
  def to_title(term, opts \\ []) do
    to_case(term, :title, opts)
  end

  @doc """
  Converts an atom or string to underscore case.
  """
  def to_underscore(term, opts \\ []) do
    to_case(term, :underscore, opts)
  end

  @doc """
  Returns `term` recased into `casing` by the resolved backend.

  Resolution order for the backend:

    1. `opts[:casing_module]` if present.
    2. `@default_casing_module` (`Recase`) otherwise.

  The backend may be a module atom, a 1- or 2-arity function, or a
  `{module, function}` tuple. When `casing` is `nil` (or omitted) it
  defaults to `@default_casing` (`:snake`).

  ## Parameters

    - `term` - `term()`. The value to recase. Forwarded unchanged to the
      resolved backend; type validation is the backend's responsibility.

    - `casing` - `atom() | nil`. Default `nil`. When `nil`, resolves to
      `:snake`. On the module-atom dispatch path must be one of `:camel`,
      `:constant`, `:dot`, `:header`, `:kebab`, `:name`, `:pascal`,
      `:path`, `:sentence`, `:snake`, `:title`, or `:underscore`. On the
      function and `{module, function}` paths the value is forwarded
      unchanged to the backend.

    - `opts` - `keyword()`. Default `[]`. Recognised key:
      `:casing_module` (`module() | (term -> term) | (term, atom -> term)
      | {module(), atom()}`). Other keys are ignored.

  ## Returns

  `term()`. Whatever the resolved backend returns from the chosen casing
  function. No global state is touched.

  ## Raises

    - `ArgumentError` - if the module-atom backend does not export the
      casing's expected function.

    - `ArgumentError` - if the casing is not in the supported list on the
      module-atom dispatch path.

    - `ArgumentError` - if a `{module, function}` backend does not export
      the named function with arity 2.

    - `ArgumentError` - if an inline-function backend has arity other
      than 1 or 2.

    - `ArgumentError` - if `opts[:casing_module]` is set to a value that
      is not a module atom, function, or `{module, function}` tuple.

    - Any exception the resolved backend itself raises (for example
      `FunctionClauseError` from `Recase` when `term` is not a string).

  ## Examples

      iex> AtlasProvider.Casing.to_case("HelloWorld")
      "hello_world"

      iex> AtlasProvider.Casing.to_case("hello_world", :camel)
      "helloWorld"

      iex> AtlasProvider.Casing.to_case("HelloWorld", :kebab)
      "hello-world"

      # Inline 2-arity backend.
      iex> AtlasProvider.Casing.to_case("x", :anything, casing_module: fn v, c -> {v, c} end)
      {"x", :anything}

  """
  @spec to_case(term(), atom() | nil, keyword()) :: term()
  def to_case(term, casing \\ nil, opts \\ []) do
    opts
    |> casing_module!()
    |> apply_casing(casing || @default_casing, term)
  end

  defp apply_casing({mod, fun}, casing, value)
       when is_atom(mod) and not is_nil(mod) and (is_atom(fun) and not is_nil(fun)) do
    ensure_function_exported!(mod, fun, 2)
    apply(mod, fun, [value, casing])
  end

  defp apply_casing(fun, casing, value) when is_function(fun) do
    case :erlang.fun_info(fun, :arity) do
      {:arity, 2} ->
        fun.(value, casing)

      {:arity, 1} ->
        fun.(value)

      {:arity, n} ->
        raise ArgumentError, "casing function must accept 1 or 2 arguments, got: #{n}"
    end
  end

  defp apply_casing(casing_module, :camel, value) do
    ensure_function_exported!(casing_module, :to_camel, 1)
    casing_module.to_camel(value)
  end

  defp apply_casing(casing_module, :constant, value) do
    ensure_function_exported!(casing_module, :to_constant, 1)
    casing_module.to_constant(value)
  end

  defp apply_casing(casing_module, :dot, value) do
    ensure_function_exported!(casing_module, :to_dot, 1)
    casing_module.to_dot(value)
  end

  defp apply_casing(casing_module, :header, value) do
    ensure_function_exported!(casing_module, :to_header, 1)
    casing_module.to_header(value)
  end

  defp apply_casing(casing_module, :kebab, value) do
    ensure_function_exported!(casing_module, :to_kebab, 1)
    casing_module.to_kebab(value)
  end

  defp apply_casing(casing_module, :pascal, value) do
    ensure_function_exported!(casing_module, :to_pascal, 1)
    casing_module.to_pascal(value)
  end

  defp apply_casing(casing_module, :path, value) do
    ensure_function_exported!(casing_module, :to_path, 1)
    casing_module.to_path(value)
  end

  defp apply_casing(casing_module, :snake, value) do
    ensure_function_exported!(casing_module, :to_snake, 1)
    casing_module.to_snake(value)
  end

  defp apply_casing(casing_module, :title, value) do
    ensure_function_exported!(casing_module, :to_title, 1)
    casing_module.to_title(value)
  end

  defp apply_casing(casing_module, :underscore, value) do
    ensure_function_exported!(casing_module, :to_underscore, 1)
    casing_module.to_underscore(value)
  end

  defp ensure_function_exported!(mod, fun, arity) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity) do
      :ok
    else
      raise ArgumentError, "Failed to load function #{mod}.#{fun}/#{arity}"
    end
  end

  # Returns `opts[:casing_module]` if provided; otherwise returns the default
  # `@default_casing_module`. Performs no assertions on the returned value.
  defp casing_module!(opts) do
    opts[:casing_module] || @default_casing_module
  end
end
