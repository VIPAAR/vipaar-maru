alias Maru.Builder.PlugRouter
alias Maru.Builder.RETURN

defmodule PlugRouter do
  defmacro __using__(opts) do
    env_config = Application.get_env(:maru, __CALLER__.module)
    versioning = Keyword.get(opts, :versioning) || (env_config || [])[:versioning] || []
    make_plug = Keyword.get(opts, :make_plug, false) or [] != versioning or not is_nil(env_config)

    [
      quote do
        @make_plug unquote(make_plug)
      end,
      if make_plug do
        quote do
          @versioning unquote(versioning)
          @pipe_functions []
          Module.register_attribute(__MODULE__, :plugs_before, accumulate: true)
          import PlugRouter.DSLs, only: [before: 1]
        end
      end
    ]
  end

  @doc false
  def before_compile_router(%Macro.Env{module: module} = env) do
    Module.get_attribute(module, :make_plug) || raise RETURN

    routes = Module.get_attribute(module, :all_routes)
    mounts = Module.get_attribute(module, :mounts) |> Enum.reverse()
    plugs_before = Module.get_attribute(module, :plugs_before) |> Enum.reverse()
    version_config = Module.get_attribute(module, :versioning)
    version_adapter = Maru.Builder.Versioning.get_adapter(version_config[:using])

    pipeline =
      [
        [{Maru.Plugs.SaveConn, [], true}],
        plugs_before,
        version_adapter.get_version_plug(version_config),
        [{:route, [], true}, {Maru.Plugs.NotFound, [], true}]
      ]
      |> List.flatten()
      |> Enum.reverse()

    {conn, body} = Plug.Builder.compile(env, pipeline, [])

    current_routes = Module.get_attribute(module, :routes) |> Enum.reverse()
    extended_routes = get_extended_routes(module)
    direct_routes = current_routes ++ extended_routes

    direct_routes_block = make_routes_block(direct_routes, env, version_adapter)

    {delegation_block, helper_modules_block} =
      make_mount_delegation(mounts, routes, env, version_adapter)

    method_not_allowed_block =
      if mounts == [] do
        make_method_not_allowed_block(routes, version_adapter)
      else
        make_method_not_allowed_block(direct_routes, version_adapter)
      end

    Module.put_attribute(module, :pipe_functions, [])
    Maru.Builder.Exception.before_build_plug(env)

    func =
      module
      |> Module.get_attribute(:pipe_functions)
      |> PlugRouter.Helper.make_pipe_functions()

    quote do
      unquote(helper_modules_block)
      unquote(direct_routes_block)
      unquote(delegation_block)
      unquote(method_not_allowed_block)
      defp route(conn, _), do: conn

      def init(_), do: []

      def call(unquote(conn), _) do
        fn ->
          unquote(body)
        end
        |> unquote(func)
        |> apply([])
      end
    end
  rescue
    RETURN -> nil
  end

  defp get_extended_routes(module) do
    current_routes = Module.get_attribute(module, :routes) |> Enum.reverse()
    mounted_routes = Module.get_attribute(module, :mounted) |> Enum.reverse()
    extend_opts = Module.get_attribute(module, :extend)

    Maru.Resource.Extend.take_extended(
      current_routes ++ mounted_routes,
      extend_opts
    )
  end

  defp make_routes_block(routes, %Macro.Env{module: module} = env, version_adapter) do
    Enum.map(routes, fn route ->
      Module.put_attribute(module, :pipe_functions, [])
      Maru.Builder.Exception.before_build_route(route, env)
      PlugRouter.Helper.dispatch(route, env, version_adapter)
    end)
  end

  defp make_mount_delegation(mounts, _all_routes, %Macro.Env{module: module} = env, version_adapter) do
    mounted_routes = Module.get_attribute(module, :mounted) |> Enum.reverse()

    if mounts == [] do
      {[], []}
    else
      {helper_names, helper_blocks} =
        mounts
        |> Enum.with_index()
        |> Enum.map(fn {mount_meta, idx} ->
          routes_for_mount = get_routes_for_mount(mounted_routes, mount_meta)

          helper_module_name = Module.concat(module, :"__MountHelper#{idx}__")

          helper_block = generate_helper_module(
            helper_module_name,
            routes_for_mount,
            env,
            version_adapter
          )

          {helper_module_name, helper_block}
        end)
        |> Enum.unzip()

      helper_names_escaped = Macro.escape(helper_names)

      delegation = quote do
        defp route(conn, []) do
          Enum.reduce_while(unquote(helper_names_escaped), conn, fn helper, conn ->
            result = helper.__maru_route__(conn, [])
            if result == conn do
              {:cont, conn}
            else
              {:halt, result}
            end
          end)
        end
      end

      {[delegation], helper_blocks}
    end
  end

  defp get_routes_for_mount(mounted_routes, mount_meta) do
    mounted_module = mount_meta.module
    resource_version = mount_meta.version
    path_prefix = mount_meta.path_prefix

    versioning_path = (is_nil(resource_version) && []) || [{:version}]
    expected_prefix = versioning_path ++ path_prefix

    Enum.filter(mounted_routes, fn route ->
      route_in_module_tree?(route, mounted_module) and
        path_has_prefix?(route.path, expected_prefix)
    end)
  end

  defp route_in_module_tree?(route, mounted_module) do
    route.module == mounted_module or
      (Map.has_key?(route, :mount_link) and mounted_module in route.mount_link)
  end

  defp path_has_prefix?(_path, []), do: true

  defp path_has_prefix?(path, prefix) do
    len = length(prefix)
    length(path) >= len and
      Enum.zip(path, prefix)
      |> Enum.all?(fn
        {_, {:version}} -> true
        {_a, b} when is_atom(b) -> true
        {a, b} -> a == b
      end)
  end

  defp generate_helper_module(helper_name, routes, %Macro.Env{module: parent} = env, version_adapter) do
    route_clauses =
      Enum.map(routes, fn route ->
        Module.put_attribute(parent, :pipe_functions, [])
        Maru.Builder.Exception.before_build_route(route, env)
        pipe_fns = Module.get_attribute(parent, :pipe_functions)

        PlugRouter.Helper.dispatch_helper_route(route, env, version_adapter, pipe_fns)
      end)

    quote do
      defmodule unquote(helper_name) do
        unquote(route_clauses)
        def __maru_route__(conn, _), do: conn
      end
    end
  end

  defp make_method_not_allowed_block(routes, version_adapter) do
    Enum.group_by(routes, fn route -> {route.version, route.path} end)
    |> Enum.map(fn {{version, path}, routes} ->
      unless Enum.any?(routes, fn i -> i.method == :match end) do
        PlugRouter.Helper.dispatch_405(version, path, version_adapter)
      end
    end)
  end
end
