defmodule FlameWorkerServer do
  @moduledoc """
  HTTP-based FLAME worker server for Apple Containers.

  Uses HTTP instead of Erlang distribution to avoid networking issues
  in containerized environments. Accepts MFA tuples for safe remote
  execution rather than arbitrary code strings.

  ## Endpoints

  - `GET /health` — health check
  - `POST /execute` — execute an MFA tuple `{module, function, args}`
  - `GET /info` — node and runtime information
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

  @allowed_modules Application.compile_env(
                     :flame_apple_container_backend,
                     :allowed_worker_modules,
                     []
                   )

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

  # Execute function endpoint — accepts MFA tuples only
  post "/execute" do
    case conn.body_params do
      %{"module" => mod_str, "function" => fun_str, "args" => args} when is_list(args) ->
        with {:ok, module} <- resolve_module(mod_str),
             {:ok, function} <- resolve_function(fun_str),
             :ok <- authorize_module(module) do
          try do
            result = apply(module, function, args)

            send_resp(
              conn,
              200,
              Jason.encode!(%{
                status: "success",
                result: result,
                timestamp: DateTime.utc_now()
              })
            )
          rescue
            error ->
              Logger.error("Function execution failed: #{inspect(error)}")

              send_resp(
                conn,
                500,
                Jason.encode!(%{
                  status: "error",
                  error: Exception.message(error),
                  timestamp: DateTime.utc_now()
                })
              )
          end
        else
          {:error, reason} ->
            send_resp(
              conn,
              403,
              Jason.encode!(%{
                status: "error",
                error: reason,
                timestamp: DateTime.utc_now()
              })
            )
        end

      _ ->
        send_resp(
          conn,
          400,
          Jason.encode!(%{
            status: "error",
            error: "Invalid request. Expected {\"module\", \"function\", \"args\": [...]}"
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
      memory: :erlang.memory() |> Map.new(),
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

  # --- Private helpers ---

  defp resolve_module(mod_str) when is_binary(mod_str) do
    module = String.to_existing_atom("Elixir." <> mod_str)
    {:ok, module}
  rescue
    ArgumentError -> {:error, "unknown module: #{mod_str}"}
  end

  defp resolve_function(fun_str) when is_binary(fun_str) do
    {:ok, String.to_existing_atom(fun_str)}
  rescue
    ArgumentError -> {:error, "unknown function: #{fun_str}"}
  end

  defp authorize_module(module) do
    allowed = allowed_modules()

    if allowed == [] or module in allowed do
      :ok
    else
      {:error, "module #{inspect(module)} is not in the allowed list"}
    end
  end

  defp allowed_modules do
    Application.get_env(:flame_apple_container_backend, :allowed_worker_modules, @allowed_modules)
  end
end
