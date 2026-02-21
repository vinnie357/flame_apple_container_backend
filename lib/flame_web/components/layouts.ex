defmodule FlameWeb.Layouts do
  @moduledoc """
  The layouts for FlameWeb.

  This module is automatically used in FlameWeb.Router where the
  :put_root_layout plug is called.
  """

  use FlameWeb, :html

  embed_templates("layouts/*")
end
