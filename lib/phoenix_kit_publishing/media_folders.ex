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

  require Logger

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Storage.Folder
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
  Parent hook: the module's `Publishing` folder at the media root, created
  on first use and remembered by uuid, so it may be renamed or moved.
  """
  @spec module_folder(atom(), String.t() | nil, term()) :: {:ok, String.t()} | {:error, term()}
  def module_folder(_kind, actor_uuid, _subject) do
    case ResourceFolders.live_folder(Settings.get_setting(@module_folder_setting)) do
      %Folder{uuid: uuid} ->
        {:ok, uuid}

      nil ->
        with {:ok, %Folder{uuid: uuid}} <-
               ResourceFolders.ensure(@module_folder_name, nil, actor_uuid) do
          remember_module_folder(uuid)
          {:ok, uuid}
        end
    end
  end

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

  # ── Group folders ──────────────────────────────────────────────────

  @doc """
  The group's folder, found or created under the parent hook's answer, the
  group's pointer written in the same locked step. A host name taken by
  another group's folder falls back to the deterministic name.
  """
  @spec ensure_group_folder(PublishingGroup.t(), String.t() | nil) ::
          {:ok, Folder.t()} | {:error, term()}
  def ensure_group_folder(%PublishingGroup{} = group, actor_uuid) do
    case ResourceFolders.live_folder(ResourceFolders.pointer_value(group, @pointer)) do
      %Folder{} = folder ->
        {:ok, folder}

      nil ->
        parent_uuid = ResourceFolders.parent_uuid(@app, :group, actor_uuid, group)
        host_name = ResourceFolders.host_name(@app, group, actor_uuid)
        deterministic = deterministic_name(group)

        ResourceFolders.ensure(host_name || deterministic, parent_uuid, actor_uuid,
          lookup: fn ->
            ResourceFolders.resolve(
              parent: parent_uuid,
              host_name: host_name,
              name: deterministic,
              anywhere: true,
              claimed?: &claimed_by_other?(&1, group)
            )
          end,
          fallback_name: deterministic,
          claim: &ResourceFolders.write_pointer(PublishingGroup, group.uuid, @pointer, &1.uuid)
        )
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
  or written then. Never raises; a file that could not be filed is named in
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
    with %PublishingGroup{} = group <- group_by_slug(slug),
         {:ok, %Folder{uuid: folder_uuid}} <- ensure_group_folder(group, actor_uuid) do
      file_uuids
      |> Enum.flat_map(&attach(&1, folder_uuid))
      |> case do
        [] -> :ok
        failures -> {:error, failures}
      end
    else
      nil ->
        {:error, :group_not_found}

      {:error, reason} = error ->
        Logger.warning(
          "[Publishing] media folder for group #{inspect(slug)} unavailable: " <>
            ResourceFolders.describe_failure(reason)
        )

        error
    end
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

  # The editor calls this in its own process: a database that raises or a
  # pool that exits must cost the filing, never the edit.
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
end
