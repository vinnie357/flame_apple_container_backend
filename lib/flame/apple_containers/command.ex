defmodule FLAME.AppleContainers.Command do
  @moduledoc """
  Direct command execution in Apple Containers.

  This module provides a simpler interface for running commands in containers
  without going through FLAME's function serialization. Useful for CLI tools
  like Claude that just need shell command execution.
  """

  require Logger

  alias FLAME.AppleContainers.CLI

  @doc """
  Execute a shell command in a container.

  ## Parameters
  - container_name: Name of the container to execute in
  - command: The command to run (as a list of strings)
  - opts: Options
    - :timeout - Command timeout in milliseconds (default: 30_000)

  ## Returns
  - {:ok, output} on success
  - {:error, reason} on failure

  ## Examples

      iex> Command.exec("my-container", ["claude", "--version"])
      {:ok, "1.0.42"}

      iex> Command.exec("my-container", ["sh", "-c", "echo hello"])
      {:ok, "hello"}
  """
  def exec(container_name, command, opts \\ []) do
    _timeout = Keyword.get(opts, :timeout, 30_000)

    Logger.debug("Executing command in container #{container_name}: #{inspect(command)}")

    case CLI.adapter().exec_in_container(container_name, command) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {error, code} ->
        Logger.warning("Command failed in container #{container_name} (exit #{code}): #{error}")
        {:error, {:exit_code, code, String.trim(error)}}
    end
  rescue
    e ->
      Logger.error("Command execution failed: #{inspect(e)}")
      {:error, {:execution_error, Exception.message(e)}}
  end

  @doc """
  Execute a shell script (via sh -c) in a container.

  ## Examples

      iex> Command.shell("my-container", "echo 'hello' | claude -p")
      {:ok, "...response..."}
  """
  def shell(container_name, script, opts \\ []) do
    exec(container_name, ["sh", "-c", script], opts)
  end

  @doc """
  List running containers matching a prefix.

  Apple Container `list` output format:
  ID  IMAGE  OS  ARCH  STATE  ADDR  CPUS  MEMORY  STARTED
  """
  def list_containers(prefix \\ "") do
    case CLI.adapter().list_containers([]) do
      {output, 0} ->
        containers =
          output
          |> String.split("\n", trim: true)
          # Skip header
          |> Enum.drop(1)
          |> Enum.map(&parse_container_line/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.filter(fn c -> prefix == "" or String.starts_with?(c.name, prefix) end)

        {:ok, containers}

      {error, _code} ->
        {:error, error}
    end
  end

  @doc """
  Get the first available running container matching a prefix.
  """
  def get_container(prefix) do
    case list_containers(prefix) do
      {:ok, containers} ->
        case Enum.find(containers, & &1.running) do
          nil -> {:error, :no_running_containers}
          container -> {:ok, container}
        end

      error ->
        error
    end
  end

  # Apple Container list format: ID IMAGE OS ARCH STATE ADDR CPUS MEMORY STARTED
  # Fields are separated by whitespace
  defp parse_container_line(line) do
    parts = String.split(line, ~r/\s+/, trim: true)

    case parts do
      [id, _image, _os, _arch, state | rest] when length(rest) >= 4 ->
        # Name is the ID for Apple Containers
        %{
          id: id,
          name: id,
          status: state,
          running: state == "running"
        }

      _ ->
        nil
    end
  end
end
