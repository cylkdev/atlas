defmodule Mix.Tasks.Atlas.Workflows.Deploy do
  @shortdoc "Run the deployment workflow (terraform plan + apply)"

  @moduledoc """
  Runs `Atlas.Pipeline.for_deployment/1` end-to-end: `terraform plan` writes
  a saved plan, then `terraform apply` consumes it. Blocks until the workflow
  finishes.

      mix atlas.workflows.deploy

  Exits with status 1 if any step failed or the run timed out.

  ## Tunnel reachability

  The pipeline includes an `aws.auto_scaling.listen` step whose
  webhook target must be reachable from AWS EventBridge.

  By default this task does **not** manage a Cloudflare tunnel —
  tunnel lifecycle is owned by `mix atlas.tunnels.start`, which can
  be run as a separate process (a separate terminal, systemd unit, or
  CI background step). The operator is responsible for bringing the
  tunnel up before invoking this task, and tearing it down
  afterwards.

  Pass `--tunnel` to let this task own the tunnel lifecycle itself.
  When the flag is set, Atlas starts the configured backend before
  the workflow runs and stops it on exit — even if the workflow fails
  or times out. This removes the need for a separate
  `mix atlas.tunnels.start` process and is the recommended shape for
  CI pipelines.

  ## Switches

    * `--tunnel` — Manage the Cloudflare tunnel lifecycle inline.
      The backend is selected by
      `Application.get_env(:atlas, :tunnel, :named)`.

    * `--tunnel-backend <name>` — Override the tunnel backend for
      this invocation. Accepts `named`, `quick`, `none`, or any
      module name like `My.Custom.Backend`. Only meaningful when
      `--tunnel` is also set. The override is written into the
      application env via `Application.put_env/3` and persists for
      the rest of the BEAM node's lifetime.

  ## Examples

  Deploy without tunnel management — operator brings the tunnel up
  separately beforehand:

      mix atlas.workflows.deploy

  Deploy with the tunnel managed inline, using whatever backend is
  configured in `config/runtime.exs` (defaults to `:named`):

      mix atlas.workflows.deploy --tunnel

  Deploy with inline tunnel, forcing the quick (temporary
  `*.trycloudflare.com`) backend regardless of config — useful for
  one-off deploys where no named tunnel is registered:

      mix atlas.workflows.deploy --tunnel --tunnel-backend quick

  Deploy with inline tunnel, explicitly selecting the named backend:

      mix atlas.workflows.deploy --tunnel --tunnel-backend named
  """

  use Mix.Task

  alias Atlas.Tunnel

  @logger_prefix "atlas.workflows.deploy"
  @requirements ["app.start", "atlas.init"]
  @await_timeout :timer.minutes(30)
  @switches [tunnel: :boolean, tunnel_backend: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      Mix.raise(
        "unrecognized flag(s): " <>
          Enum.map_join(invalid, ", ", fn {flag, _} -> flag end) <>
          " (run `mix help atlas.workflows.deploy` for usage)"
      )
    end

    if opts[:tunnel_backend] && !opts[:tunnel] do
      Mix.raise("--tunnel-backend requires --tunnel")
    end

    if opts[:tunnel_backend] do
      backend =
        Mix.Tasks.Atlas.Tunnels.Start.parse_backend_override!(opts[:tunnel_backend])

      Application.put_env(:atlas, :tunnel, backend)
    end

    run_workflow = fn -> execute_workflow() end

    if opts[:tunnel] do
      with_tunnel(run_workflow)
    else
      run_workflow.()
    end
  end

  @doc """
  Start the configured tunnel backend, call `fun`, then stop the
  backend — even if `fun` raises or exits. Returns the value
  returned by `fun`.

  Exposed as a public function so tests can verify the tunnel
  lifecycle without booting a real workflow. Use
  `Atlas.Tunnel.Stub` (available in the `:test` env) as the
  configured backend in tests.

  Raises `Mix.Error` if the backend fails to start or fails to
  report a URL.
  """
  @spec with_tunnel((-> result)) :: result when result: term()
  def with_tunnel(fun) do
    backend = Tunnel.backend()
    Atlas.Log.info(@logger_prefix, "starting tunnel backend #{inspect(backend)}")

    case Tunnel.start_link([]) do
      {:ok, pid} ->
        try do
          log_tunnel_url(pid)
          fun.()
        after
          Tunnel.stop(pid)
          Atlas.Log.info(@logger_prefix, "tunnel stopped")
        end

      {:error, reason} ->
        Mix.raise(
          "could not start tunnel: #{inspect(reason)} " <>
            "(backend #{inspect(backend)})"
        )
    end
  end

  # --------------------------------------------------------------------

  defp execute_workflow do
    workflow_id = generate_id()
    Atlas.Log.info("workflow:#{workflow_id}", "deployment task starting")

    workflow = Atlas.Pipeline.for_deployment(workflow_id)

    case Atlas.Workflows.run(workflow, await: true, await_timeout: @await_timeout) do
      {:ok, %Atlas.Workflow{errors: errors} = final} when map_size(errors) == 0 ->
        Atlas.Log.info("workflow:#{final.id}", "deployment task succeeded")

      {:ok, %Atlas.Workflow{} = final} ->
        Enum.each(final.errors, fn {step_id, errs} ->
          Atlas.Log.error(
            "workflow:#{final.id}:#{step_id}",
            "#{length(errs)} diagnostic(s)"
          )
        end)

        Atlas.Log.error("workflow:#{final.id}", "deployment task failed")
        exit({:shutdown, 1})

      {:error, reason} ->
        Atlas.Log.error("workflow:#{workflow_id}", "run returned #{inspect(reason)}")
        Mix.raise("deployment workflow failed: #{inspect(reason)}")
    end
  end

  defp log_tunnel_url(pid) do
    case Tunnel.url(pid) do
      {:ok, url} ->
        Atlas.Log.info(@logger_prefix, "tunnel up at #{url}")

      {:error, :no_tunnel} ->
        Atlas.Log.info(@logger_prefix, "no tunnel configured (:none backend) — no URL")

      {:error, reason} ->
        Mix.raise(
          "tunnel failed to report URL: #{inspect(reason)} " <>
            "(backend #{inspect(Tunnel.backend())})"
        )
    end
  end

  defp generate_id do
    "deploy-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
  end
end
