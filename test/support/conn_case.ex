defmodule FlameWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use FlameWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # Try to forcefully start floki if it's not already started
      case Application.start(:floki) do
        :ok -> :ok
        {:error, {:already_started, :floki}} -> :ok
        {:error, _} -> :ok
      end
      
      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import FlameWeb.ConnCase

      # The default endpoint for testing
      @endpoint FlameWeb.Endpoint
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
