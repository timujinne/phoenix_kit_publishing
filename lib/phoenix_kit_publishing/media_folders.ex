defmodule PhoenixKit.Modules.Publishing.MediaFolders do
  @moduledoc """
  One media folder per publishing group, on core's per-record folder
  convention (`PhoenixKit.Modules.Storage.ResourceFolders`).

  ## Opt-in

  Nothing happens until the host configures the parent hook: no folder is
  created and a picked file stays where it is. The module ships a
  ready-made pair — a `Publishing` folder at the root, one folder per
  group inside it, named after the group:

      config :phoenix_kit_publishing,
        attachments_parent_folder: {PhoenixKit.Modules.Publishing.MediaFolders, :module_folder},
        attachments_folder_name: {PhoenixKit.Modules.Publishing.MediaFolders, :group_folder_name}

  Either key can name the host's own function instead. The parent hook is
  called as `fun(:group, actor_uuid, group)` (or `fun(:group, actor_uuid)`)
  and answers `{:ok, folder_uuid}`, or `nil` for the media root; the name
  hook as `fun(group, actor_uuid)`, answering `{:ok, name}`, or `nil` for
  the deterministic `publishing-group-<uuid>`.

  ## Pointers

  A group keeps its folder's uuid in `data["media_folder_uuid"]`, and the
  ready-made parent hook keeps the module folder's in the
  `publishing_media_folder_uuid` setting — so a folder renamed or moved in
  the media browser is still the one used.

  ## Filing

  `file_for_group/3` puts files into a group's folder by core's attach
  rule: a file with no home is adopted, a file homed elsewhere is linked
  (it keeps its home), a file already there is left alone. The editor
  calls it for every file chosen in the media picker; files that predate
  the configuration are filed by `PhoenixKit.Modules.Publishing.MediaAdoption`.
  Moving a group folder after the host changes its hooks is the core
  media reorganizer's job (`PhoenixKit.Modules.Publishing.MediaReorganizer`).
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.ResourceFolders
  alias PhoenixKit.Settings

  @app :phoenix_kit_publishing
  @pointer {:data, "media_folder_uuid"}
  @prefix "publishing-group-"
  @module_folder_name "Publishing"
  @module_folder_setting "publishing_media_folder_uuid"

  @doc "The OTP app whose hooks decide where group folders go."
  @spec app() :: atom()
  def app, do: @app

  @doc "Where a group keeps its folder uuid (`t:ResourceFolders.pointer/0`)."
  @spec pointer() :: ResourceFolders.pointer()
  def pointer, do: @pointer

  @doc "The prefix of a group folder's deterministic name."
  @spec folder_prefix() :: String.t()
  def folder_prefix, do: @prefix

  @doc "Whether the host has opted in (configured the parent hook)."
  @spec enabled?() :: boolean()
  def enabled?, do: ResourceFolders.hook_configured?(@app)

  @doc "The folder name a group falls back to: `publishing-group-<uuid>`."
  @spec deterministic_name(PublishingGroup.t()) :: String.t()
  def deterministic_name(%PublishingGroup{uuid: uuid}), do: @prefix <> uuid

  # ── Ready-made hooks ───────────────────────────────────────────────

  @doc """
  Parent hook: the module's `Publishing` folder at the root of the site's
  media library (Media), created on first use and remembered by uuid, so it
  may be renamed or moved. A folder of that name in any other library — a
  person's private one — is never taken for it.
  """
  @spec module_folder(atom(), String.t() | nil, term()) :: {:ok, String.t()} | {:error, term()}
  def module_folder(_kind, actor_uuid, _subject) do
    case media_folder(Settings.get_setting(@module_folder_setting)) do
      %Folder{uuid: uuid} ->
        {:ok, uuid}

      nil ->
        with {:ok, %Folder{uuid: uuid}} <-
               ResourceFolders.ensure(@module_folder_name, nil, actor_uuid,
                 lookup: &media_root_module_folder/0
               ) do
          remember_module_folder(uuid)
          {:ok, uuid}
        end
    end
  end

  # Core's by-name lookups do not look at the library (`find_under/2` takes
  # the first live folder of that name at the root of ANY library), so the
  # module folder is looked up here, in Media only. A new one is created in
  # Media too: that is where a folder without a library goes.
  defp media_root_module_folder do
    from(f in Folder,
      where: f.name == ^@module_folder_name and is_nil(f.parent_uuid) and is_nil(f.trashed_at),
      where: f.library_uuid == ^Libraries.media_uuid(),
      order_by: [asc: f.inserted_at, asc: f.uuid],
      limit: 1
    )
    |> repo().one()
  end

  defp media_folder(uuid) do
    case ResourceFolders.live_folder(uuid) do
      %Folder{} = folder -> if in_media?(folder), do: folder
      nil -> nil
    end
  end

  defp in_media?(%Folder{library_uuid: library_uuid}), do: Libraries.media?(library_uuid)

  defp remember_module_folder(uuid) do
    case Settings.update_setting(@module_folder_setting, uuid) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Publishing] could not remember the media folder: " <>
            ResourceFolders.describe_failure(reason)
        )
    end
  end

  @doc "Name hook: a group's folder is called after the group."
  @spec group_folder_name(term(), String.t() | nil) :: {:ok, String.t()} | nil
  def group_folder_name(%PublishingGroup{name: name}, _actor_uuid)
      when is_binary(name) and name != "",
      do: {:ok, name}

  def group_folder_name(_subject, _actor_uuid), do: nil

  @doc """
  What is wrong with the configured hooks, without calling them: a key that
  is not a `{module, function}` pair, or names a function that is not
  exported (the parent hook at arity 3 or 2, the name hook at arity 2).
  `[]` when both are fine or unset.
  """
  @spec hook_problems() :: [String.t()]
  def hook_problems do
    [
      hook_problem(:attachments_parent_folder, [3, 2]),
      hook_problem(:attachments_folder_name, [2])
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp hook_problem(key, arities) do
    case Application.get_env(@app, key) do
      nil ->
        nil

      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        if Code.ensure_loaded?(mod) and Enum.any?(arities, &function_exported?(mod, fun, &1)),
          do: nil,
          else: "#{key}: #{inspect(mod)}.#{fun} is not callable"

      _other ->
        "#{key}: not a {module, function} pair"
    end
  end

  # ── Group folders ──────────────────────────────────────────────────

  @doc """
  The group's folder, found or created under the parent hook's answer, the
  group's pointer written in the same locked step. A host name taken by
  another group's folder falls back to the deterministic name. Only folders
  of the site's media library (Media) are ever adopted.

  A failing hook falls back to the media root and the deterministic name,
  logged — an upload never fails on a host hook. With `strict: true` (the
  one-time adoption) a failing hook is `{:error, {:parent_hook | :name_hook,
  reason}}` instead and nothing is created.
  """
  @spec ensure_group_folder(PublishingGroup.t(), String.t() | nil, keyword()) ::
          {:ok, Folder.t()} | {:error, term()}
  def ensure_group_folder(%PublishingGroup{} = group, actor_uuid, opts \\ []) do
    strict? = Keyword.get(opts, :strict, false)

    case media_folder(ResourceFolders.pointer_value(group, @pointer)) do
      %Folder{} = folder ->
        {:ok, folder}

      nil ->
        with {:ok, parent_uuid} <- parent_for(group, actor_uuid, strict?),
             {:ok, host_name} <- name_for(group, actor_uuid, strict?) do
          create_group_folder(group, parent_uuid, host_name, actor_uuid)
        end
    end
  end

  # Core's by-name lookups (`ResourceFolders.resolve/1`, and the "is the
  # name taken" check inside `ensure/4`) do not look at the library and
  # take the first row without an order, so at the root — a hook that
  # answers `nil` — a person's private `News` could be adopted or could push
  # the group onto its fallback name. The lookup and the name choice are
  # therefore made here, in Media, oldest first; `ensure/4` is only asked to
  # create (race-safe, claimed under its lock).
  defp create_group_folder(group, parent_uuid, host_name, actor_uuid) do
    deterministic = deterministic_name(group)
    lookup = fn -> find_group_folder(group, parent_uuid, host_name, deterministic) end

    name =
      if is_binary(host_name) and media_folder_named(host_name, parent_uuid),
        do: deterministic,
        else: host_name || deterministic

    ResourceFolders.ensure(name, parent_uuid, actor_uuid,
      lookup: lookup,
      claim: &ResourceFolders.write_pointer(PublishingGroup, group.uuid, @pointer, &1.uuid)
    )
  end

  # `ResourceFolders.resolve/1`'s order, in Media only: the host name
  # directly under the parent unless another group points at that folder,
  # then the deterministic name under the parent, at the root, anywhere.
  defp find_group_folder(group, parent_uuid, host_name, deterministic) do
    host_folder(group, parent_uuid, host_name, deterministic) ||
      deterministic_folder(deterministic, parent_uuid)
  end

  defp host_folder(group, parent_uuid, host_name, deterministic)
       when is_binary(host_name) and host_name != deterministic do
    case media_folder_named(host_name, parent_uuid) do
      %Folder{} = folder -> if claimed_by_other?(folder, group), do: nil, else: folder
      nil -> nil
    end
  end

  defp host_folder(_group, _parent_uuid, _host_name, _deterministic), do: nil

  defp media_folder_named(name, parent_uuid) do
    media_folders_named(name)
    |> where([f], ^directly_under(parent_uuid))
    |> limit(1)
    |> repo().one()
  end

  defp deterministic_folder(name, parent_uuid) do
    name
    |> media_folders_named()
    |> repo().all()
    |> Enum.min_by(&place_rank(&1, parent_uuid), fn -> nil end)
  end

  defp media_folders_named(name) do
    from(f in Folder,
      where: f.name == ^name and is_nil(f.trashed_at),
      where: f.library_uuid == ^Libraries.media_uuid(),
      order_by: [asc: f.inserted_at, asc: f.uuid]
    )
  end

  defp directly_under(nil), do: dynamic([f], is_nil(f.parent_uuid))
  defp directly_under(parent_uuid), do: dynamic([f], f.parent_uuid == ^parent_uuid)

  # Rows come oldest first and `Enum.min_by/3` keeps the first of equal
  # ranks: under the parent, then at the root, then anywhere.
  defp place_rank(%Folder{parent_uuid: parent}, parent), do: 0
  defp place_rank(%Folder{parent_uuid: nil}, _parent), do: 1
  defp place_rank(%Folder{}, _parent), do: 2

  defp parent_for(group, actor_uuid, false),
    do: {:ok, ResourceFolders.parent_uuid(@app, :group, actor_uuid, group)}

  defp parent_for(group, actor_uuid, true) do
    case ResourceFolders.parent_hook(@app, :group, actor_uuid, group) do
      {:ok, parent_uuid} -> {:ok, parent_uuid}
      :unconfigured -> {:ok, nil}
      {:error, reason} -> {:error, {:parent_hook, reason}}
    end
  end

  defp name_for(group, actor_uuid, false),
    do: {:ok, ResourceFolders.host_name(@app, group, actor_uuid)}

  defp name_for(group, actor_uuid, true) do
    case ResourceFolders.name_hook(@app, group, actor_uuid) do
      {:ok, name} -> {:ok, name}
      :unconfigured -> {:ok, nil}
      {:error, reason} -> {:error, {:name_hook, reason}}
    end
  end

  # A host name carries no uuid, so two groups can share one; a folder
  # another group points at is never taken. Fails closed.
  defp claimed_by_other?(%Folder{uuid: folder_uuid}, %PublishingGroup{uuid: own_uuid}),
    do: ResourceFolders.claimed?(folder_uuid, own_uuid, [{PublishingGroup, @pointer}])

  # ── Filing files ───────────────────────────────────────────────────

  @doc """
  Puts `file_uuids` into the folder of the group `slug` (see the moduledoc's
  "Filing"). `:disabled` on a host that has not opted in — nothing is read
  or written then. A trashed group is `{:error, :group_not_active}` (the
  one-time adoption skips those too), and a system-managed file is left
  alone. Never raises; a file that could not be filed is named in
  `{:error, [{file_uuid, reason}]}` and logged.
  """
  @spec file_for_group(String.t(), [String.t()], String.t() | nil) ::
          :ok | :disabled | {:error, term()}
  def file_for_group(slug, file_uuids, actor_uuid) when is_list(file_uuids) do
    if enabled?() do
      guarded(fn -> do_file_for_group(slug, Enum.uniq(file_uuids), actor_uuid) end)
    else
      :disabled
    end
  end

  defp do_file_for_group(_slug, [], _actor_uuid), do: :ok

  defp do_file_for_group(slug, file_uuids, actor_uuid) do
    with %PublishingGroup{status: "active"} = group <- group_by_slug(slug),
         {:ok, %Folder{uuid: folder_uuid}} <- ensure_group_folder(group, actor_uuid) do
      file_uuids
      |> without_system_managed()
      |> Enum.flat_map(&attach(&1, folder_uuid))
      |> case do
        [] -> :ok
        failures -> {:error, failures}
      end
    else
      nil ->
        not_filed(slug, :group_not_found)

      %PublishingGroup{} ->
        not_filed(slug, :group_not_active)

      {:error, reason} = error ->
        Logger.warning(
          "[Publishing] media folder for group #{inspect(slug)} unavailable: " <>
            ResourceFolders.describe_failure(reason)
        )

        error
    end
  end

  # Tile chunks and an edited image's hidden original are core's own
  # bookkeeping; the picker never offers them, and a forged event must not
  # file one either.
  defp without_system_managed(file_uuids) do
    uuids = Enum.flat_map(file_uuids, &cast/1)

    managed =
      from(f in StorageFile, where: f.uuid in ^uuids and f.system_managed, select: f.uuid)
      |> repo().all()

    Enum.reject(file_uuids, fn uuid -> Enum.any?(cast(uuid), &(&1 in managed)) end)
  end

  defp not_filed(slug, reason) do
    Logger.warning("[Publishing] nothing filed for group #{inspect(slug)}: #{inspect(reason)}")
    {:error, reason}
  end

  defp attach(file_uuid, folder_uuid) do
    case ResourceFolders.attach(file_uuid, folder_uuid) do
      {:ok, _outcome} ->
        []

      {:error, reason} ->
        Logger.warning(
          "[Publishing] file #{inspect(file_uuid)} not filed into #{folder_uuid}: " <>
            ResourceFolders.describe_failure(reason)
        )

        [{file_uuid, reason}]
    end
  end

  defp group_by_slug(slug) when is_binary(slug), do: DBStorage.get_group_by_slug(slug)
  defp group_by_slug(_slug), do: nil

  # The editor calls this from a task: a database that raises or a pool that
  # exits must cost the filing, never anything else.
  defp guarded(fun) do
    fun.()
  rescue
    error -> failed(error)
  catch
    :exit, reason -> failed({:exit, reason})
  end

  defp failed(reason) do
    Logger.warning(
      "[Publishing] filing into a group folder failed: " <>
        ResourceFolders.describe_failure(reason)
    )

    {:error, reason}
  end

  defp cast(value) when is_binary(value) and byte_size(value) == 36 do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> [String.downcase(uuid)]
      :error -> []
    end
  end

  defp cast(_value), do: []

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
