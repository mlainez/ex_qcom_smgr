defmodule ExQcomSmgr.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      Enum.map(ExQcomSmgr.types(), fn type ->
        Supervisor.child_spec({ExQcomSmgr.Worker, type}, id: type)
      end)

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: ExQcomSmgr.Supervisor
    )
  end
end
