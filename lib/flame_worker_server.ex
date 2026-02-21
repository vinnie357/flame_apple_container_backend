defmodule FlameWorkerServer do
  @moduledoc """
  HTTP-based FLAME worker server for Apple Containers.

  Uses HTTP instead of Erlang distribution to avoid networking issues
  in containerized environments.
  """

  use Plug.Router
  require Logger

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  # Health check endpoint
  get "/health" do
    send_resp(
      conn,
      200,
      Jason.encode!(%{
        status: "healthy",
        node: Node.self(),
        timestamp: DateTime.utc_now()
      })
    )
  end

  # Execute function endpoint
  post "/execute" do
    case conn.body_params do
      %{"function" => function_code, "args" => args} ->
        try do
          # Execute the function safely
          {result, _binding} = Code.eval_string(function_code, args: args)

          response = %{
            status: "success",
            result: result,
            timestamp: DateTime.utc_now()
          }

          send_resp(conn, 200, Jason.encode!(response))
        rescue
          error ->
            Logger.error("Function execution failed: #{inspect(error)}")

            response = %{
              status: "error",
              error: inspect(error),
              timestamp: DateTime.utc_now()
            }

            send_resp(conn, 500, Jason.encode!(response))
        end

      _ ->
        send_resp(
          conn,
          400,
          Jason.encode!(%{
            status: "error",
            error: "Invalid request format"
          })
        )
    end
  end

  # Get node information
  get "/info" do
    info = %{
      node: Node.self(),
      container_id: System.get_env("HOSTNAME", "unknown"),
      uptime_ms: :erlang.monotonic_time(:millisecond),
      memory: :erlang.memory(),
      process_count: length(Process.list()),
      timestamp: DateTime.utc_now()
    }

    send_resp(conn, 200, Jason.encode!(info))
  end

  match _ do
    send_resp(
      conn,
      404,
      Jason.encode!(%{
        status: "error",
        error: "Not found"
      })
    )
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  def start_link(opts \\ []) do
    port = Keyword.get(opts, :port, 4000)
    Logger.info("Starting FlameWorkerServer on port #{port}")

    Plug.Cowboy.http(__MODULE__, [], port: port)
  end
end
