defmodule ActivityPub.Web do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, views, channels and so on.

  This can be used in your application as:

      use ActivityPub.Web, :controller
      use ActivityPub.Web, :view

  The definitions below will be executed for every view,
  controller, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define any helper function in modules
  and import those modules here.
  """

  import Untangle
  alias ActivityPub.Config

  def controller do
    quote do
      use Phoenix.Controller, namespace: ActivityPub.Web

      import Plug.Conn
      alias ActivityPub.Web.Router.Helpers, as: Routes

      @doc """
      Rate limit plug for controllers.

      Reads configuration from `Application.get_env(:activity_pub, :rate_limit)[key_prefix]` with fallback to default options provided in the plug call.

      ## Options

        * `:key_prefix` - Prefix for the rate limit bucket key (required)
        * `:scale_ms` - Default time window in milliseconds (can be overridden by config)
        * `:limit` - Default number of requests (can be overridden by config)

      ## Examples

          plug :rate_limit, 
            key_prefix: :webfinger,
            scale_ms: 60_000,
            limit: 200
      """
      def rate_limit(conn, opts) do
        key_prefix = Keyword.fetch!(opts, :key_prefix)

        # Read from config, falling back to defaults
        config = Application.get_env(:activity_pub, :rate_limit, [])[key_prefix] || []
        scale_ms = Keyword.get(config, :scale_ms) || Keyword.get(opts, :scale_ms, 60_000)
        limit = Keyword.get(config, :limit) || Keyword.get(opts, :limit, 200)

        # Build rate limit key from IP
        ip = conn.remote_ip |> :inet.ntoa() |> to_string()
        key = "#{key_prefix}:#{ip}"

        case ActivityPub.RateLimit.hit(key, scale_ms, limit) do
          {:allow, _count} ->
            conn

          {:deny, retry_after} ->
            ActivityPub.Web.rate_limit_reached(conn, retry_after)
        end
      end
    end
  end

  def view do
    quote do
      # use Phoenix.View,
      #   root: "lib/activity_pub_web/templates",
      #   namespace: ActivityPub.Web
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_flash: 1, get_flash: 2, view_module: 1]

      # Include shared imports and aliases for views
      unquote(view_helpers())
    end
  end

  def router do
    quote do
      use Phoenix.Router

      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  defp view_helpers do
    quote do
      # Import basic rendering functionality (render, render_layout, etc)
      # import Phoenix.View

      alias ActivityPub.Web.Router.Helpers, as: Routes
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end

  ### Helpers ###

  def base_url do
    ActivityPub.Federator.Adapter.base_url() || ActivityPub.Web.Endpoint.url()
  end

  def rate_limit_reached(conn, retry_after) when is_integer(retry_after) do
    conn
    |> Plug.Conn.put_resp_header("retry-after", retry_after |> div(1000) |> Integer.to_string())
    |> Plug.Conn.send_resp(429, "Too Many Requests")
    |> Plug.Conn.halt()
  end

  def rate_limit_reached(conn, opts) when is_list(opts) do
    import Untangle

    limit_ms =
      Keyword.get(opts, :limit_ms) ||
        ActivityPub.Config.get(
          Map.get(conn.private, :phoenix_controller) || :default_rate_limit_ms
        ) || 10_000

    conn
    |> Plug.Conn.put_resp_header("retry-after", limit_ms |> div(1000) |> Integer.to_string())
    |> Plug.Conn.send_resp(429, "Too Many Requests")
    |> warn("responding with 429 Too Many Requests and retry-after header")
    |> Plug.Conn.halt()
  end
end
