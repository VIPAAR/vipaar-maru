alias Maru.Resource

defmodule Resource do
  defstruct path: [],
            parameters: [],
            plugs: [],
            helpers: [],
            version: nil

  defmacro __using__(_) do
    quote do
      import Resource.DSLs
      Module.register_attribute(__MODULE__, :mounted, accumulate: true)
      Module.register_attribute(__MODULE__, :mounts, accumulate: true)
      Module.register_attribute(__MODULE__, :endpoints, accumulate: true)
      Module.register_attribute(__MODULE__, :routes, accumulate: true)

      @resource %Resource{}
      @extend nil
      @router nil
    end
  end

  def before_compile_router(%Macro.Env{module: module}) do
    current_routes = Module.get_attribute(module, :routes) |> Enum.reverse()
    mounted_routes = Module.get_attribute(module, :mounted) |> Enum.reverse()
    extend_opts = Module.get_attribute(module, :extend)

    extended =
      Resource.Extend.take_extended(
        current_routes ++ mounted_routes,
        extend_opts
      )

    all_routes = current_routes ++ mounted_routes ++ extended
    Module.put_attribute(module, :all_routes, all_routes)

    make_plug = Module.get_attribute(module, :make_plug) || false
    mounts = Module.get_attribute(module, :mounts) |> Enum.reverse()

    routes_func =
      if make_plug and mounts != [] do
        mounts_for_runtime =
          Enum.map(mounts, fn m ->
            %{module: m.module, version: m.version, path_prefix: m.path_prefix,
              parameters: m.parameters}
          end)

        quote do
          def __routes__ do
            current = unquote(Macro.escape(current_routes))
            extended = unquote(Macro.escape(extended))

            mounted =
              Enum.flat_map(unquote(Macro.escape(mounts_for_runtime)), fn mount ->
                Enum.map(mount.module.__routes__(), fn route ->
                  versioning_path = (is_nil(mount.version) && []) || [{:version}]
                  %{route |
                    version: route.version || mount.version,
                    path: versioning_path ++ mount.path_prefix ++ route.path,
                    parameters: mount.parameters ++ route.parameters
                  }
                end)
              end)

            current ++ mounted ++ extended
          end
        end
      else
        quote do
          def __routes__, do: unquote(Macro.escape(all_routes))
        end
      end

    [
      routes_func,
      Module.get_attribute(module, :endpoints)
      |> Enum.reverse()
      |> Enum.map(&Resource.Helper.dispatch/1)
    ]
  end
end
