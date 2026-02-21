#!/bin/bash
set -e

echo "Starting simple FLAME worker"
echo "NODE_NAME: ${NODE_NAME}"
echo "ERLANG_COOKIE: ${ERLANG_COOKIE}"

# Start a simple Elixir application that just runs forever
cd /app
exec elixir -e "
defmodule SimpleWorker do
  def start do
    IO.puts(\"SimpleWorker started at #{DateTime.utc_now()}\")
    loop()
  end
  
  defp loop do
    Process.sleep(1000)
    IO.puts(\"Worker alive at #{DateTime.utc_now()}\")
    loop()
  end
end

SimpleWorker.start()
"