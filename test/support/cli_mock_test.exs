defmodule FLAME.AppleContainers.CLI.Mock do
  @moduledoc """
  Mock CLI adapter for testing.

  Uses the process dictionary to allow per-test response configuration.
  Each test can set expected responses via `set_response/2`.

  ## Usage in tests

      setup do
        Application.put_env(:flame_apple_container_backend, :cli_adapter, FLAME.AppleContainers.CLI.Mock)
        on_exit(fn -> Application.delete_env(:flame_apple_container_backend, :cli_adapter) end)
      end

      test "handles dns list" do
        FLAME.AppleContainers.CLI.Mock.set_response(:list_dns_domains, {"example.local\\n", 0})
        # ... test code that calls through the adapter
      end
  """

  @behaviour FLAME.AppleContainers.CLI

  @doc """
  Set the mock response for a callback function.

  The response should be a `{output, exit_code}` tuple, or a function
  that returns one (for dynamic responses).
  """
  def set_response(callback, response) do
    Process.put({__MODULE__, callback}, response)
  end

  @doc """
  Set multiple mock responses at once.
  """
  def set_responses(responses) when is_map(responses) do
    Enum.each(responses, fn {callback, response} ->
      set_response(callback, response)
    end)
  end

  @doc """
  Clear all mock responses.
  """
  def clear_responses do
    Process.get_keys()
    |> Enum.filter(fn
      {__MODULE__, _} -> true
      _ -> false
    end)
    |> Enum.each(&Process.delete/1)
  end

  defp get_response(callback, default \\ {"", 1}) do
    case Process.get({__MODULE__, callback}) do
      nil -> default
      fun when is_function(fun, 0) -> fun.()
      response -> response
    end
  end

  @impl true
  def list_dns_domains, do: get_response(:list_dns_domains)

  @impl true
  def run_container(_args), do: get_response(:run_container)

  @impl true
  def stop_container(_name, _opts \\ []), do: get_response(:stop_container)

  @impl true
  def kill_container(_name), do: get_response(:kill_container)

  @impl true
  def inspect_container(_name), do: get_response(:inspect_container)

  @impl true
  def list_containers(_args \\ []), do: get_response(:list_containers)

  @impl true
  def get_container_stats(_name, _args \\ []), do: get_response(:get_container_stats)

  @impl true
  def exec_in_container(_name, _command), do: get_response(:exec_in_container)

  @impl true
  def list_images(_args \\ []), do: get_response(:list_images)

  @impl true
  def build_image(_args), do: get_response(:build_image)

  @impl true
  def hostname, do: get_response(:hostname, {"mock-host.local\n", 0})
end
