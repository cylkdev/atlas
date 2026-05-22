defmodule Atlas.SdNotify.HealthCheck do
  @moduledoc """
  Behaviour for the liveness predicate consumed by
  `Atlas.SdNotify`.

  An implementation returns `true` when the service is healthy enough to
  keep telling systemd "I am alive" (`WATCHDOG=1`), and `false` when
  systemd should be allowed to restart the unit on its next watchdog
  timeout.
  """

  @callback healthy?() :: boolean()
end
