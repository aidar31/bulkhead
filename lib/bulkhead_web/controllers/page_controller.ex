defmodule BulkheadWeb.PageController do
  use BulkheadWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
