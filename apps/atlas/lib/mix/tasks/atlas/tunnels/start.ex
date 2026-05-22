defmodule Mix.Tasks.Atlas.Tunnels.Start do
  @shortdoc "Starts the Cloudflare tunnel that fronts Atlas events"

  @moduledoc """
  Provisions a remote-managed Cloudflare tunnel via `Flared.MixTask.run_remote/3`
  and runs `cloudflared` in the foreground, routing the public Atlas hostname
  to a locally-running HTTP listener. Cloudflare-side state is deprovisioned
  when `cloudflared` exits.

  This task does NOT start the `:atlas` application — only `:flared` and
  its dependencies. Run your listener (e.g. Bandit) in a separate terminal.

  ## Usage

      mix atlas.tunnel.start [--forward-to <host:port>] \\
        [--name <tunnel-name>] \\
        [--hostname <public-host>] \\
        [--scheme http|https] \\
        [--service-domain <host>] \\
        [--service-port <port>]

  Defaults:

    * `--name` — `"atlas-events"`
    * `--hostname` — `"atlas-events.cylk.dev"`
    * `--scheme` — `:http`
    * `--service-domain` — `"localhost"`
    * `--service-port` — `4000`

  ## `--forward-to` shorthand

  `--forward-to` sets `--scheme`, `--service-domain`, and `--service-port`
  in one go. Accepted forms:

    * `host:port`               (e.g. `localhost:4000`)
    * `scheme://host:port`      (e.g. `http://localhost:4000`)

  Explicit `--scheme` / `--service-domain` / `--service-port` flags
  override the values derived from `--forward-to`.

  ## Examples

  Open the default tunnel (`atlas-events` → `atlas-events.cylk.dev` →
  `http://localhost:4000`):

      mix atlas.tunnel.start

  Forward to a different local port:

      mix atlas.tunnel.start --forward-to localhost:4001

  Forward to an https backend:

      mix atlas.tunnel.start --forward-to https://localhost:4443

  Use a different public hostname and tunnel name:

      mix atlas.tunnel.start \\
        --name kurt-atlas-events \\
        --hostname kurt-atlas-events.cylk.dev
  """

  use Mix.Task

  @logger_prefix "Mix.Tasks.Atlas.Tunnels.Start"

  @switches [
    forward_to: :string,
    name: :string,
    hostname: :string,
    scheme: :string,
    service_domain: :string,
    service_port: :integer
  ]

  @default_name "atlas-events"
  @default_hostname "atlas-events.cylk.dev"
  @default_scheme :http
  @default_service_domain "localhost"
  @default_service_port 4000

  @impl Mix.Task
  def run(args) do
    {:ok, _started} = Application.ensure_all_started(:flared)

    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    opts = normalize(opts)

    name = opts[:name] || @default_name
    hostname = opts[:hostname] || @default_hostname
    service = service_uri(opts)

    Atlas.Log.info(@logger_prefix, "provisioning tunnel #{name} #{hostname} -> #{service}")

    routes = [%{hostname: hostname, service: service}]

    case Flared.MixTask.run_remote(name, routes, []) do
      :ok ->
        Atlas.Log.info(@logger_prefix, "tunnel #{name} exited cleanly")

      {:error, reason} ->
        Atlas.Log.error(@logger_prefix, "tunnel #{name} failed: #{inspect(reason)}")
        Mix.raise("Cloudflare tunnel failed: #{inspect(reason)}")
    end
  end

  defp normalize(opts) do
    {forward_to, opts} = Keyword.pop(opts, :forward_to)

    opts
    |> apply_forward_to(forward_to)
    |> Enum.map(fn
      {:scheme, raw} when is_binary(raw) -> {:scheme, parse_scheme(raw)}
      other -> other
    end)
  end

  defp apply_forward_to(opts, nil), do: opts

  defp apply_forward_to(opts, raw) when is_binary(raw) do
    parsed = parse_forward_to(raw)
    # Explicit per-part flags win over --forward-to.
    Keyword.merge(parsed, opts)
  end

  defp parse_forward_to(raw) do
    case String.split(raw, "://", parts: 2) do
      [scheme, rest] ->
        [{:scheme, parse_scheme(scheme)} | parse_host_port(rest)]

      [rest] ->
        parse_host_port(rest)
    end
  end

  defp parse_host_port(raw) do
    case String.split(raw, ":", parts: 2) do
      [host, port_str] ->
        case Integer.parse(port_str) do
          {port, ""} ->
            [service_domain: host, service_port: port]

          _ ->
            Mix.raise(~s(--forward-to port must be an integer, got: #{inspect(port_str)}))
        end

      [_host_only] ->
        Mix.raise(~s(--forward-to must be in the form "host:port", got: #{inspect(raw)}))
    end
  end

  defp parse_scheme("http"), do: :http
  defp parse_scheme("https"), do: :https
  defp parse_scheme(:http), do: :http
  defp parse_scheme(:https), do: :https

  defp parse_scheme(other) do
    Mix.raise(~s(scheme must be "http" or "https", got: #{inspect(other)}))
  end

  defp service_uri(opts) do
    scheme = opts[:scheme] || @default_scheme
    service_domain = opts[:service_domain] || @default_service_domain
    service_port = opts[:service_port] || @default_service_port
    "#{scheme}://#{service_domain}:#{service_port}"
  end
end
