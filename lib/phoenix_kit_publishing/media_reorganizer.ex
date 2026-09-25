defmodule PhoenixKit.Modules.Publishing.MediaReorganizer do
  @moduledoc """
  Publishing's plan source for core's media reorganizer
  (`mix phoenix_kit.media.reorganize`), registered through
  `PhoenixKit.Modules.Publishing.media_reorganizer/0`.

  The group folders of `PhoenixKit.Modules.Publishing.MediaFolders` are
  planned by core's `PhoenixKit.Modules.Storage.Reorganizer.ResourceSource`,
  which applies the whole `Reorganizer.Source` contract: when the host's
  hooks change, a group's folder moves under the new parent (a folder
  found by its deterministic `publishing-group-<uuid>` name is renamed
  after the name hook and its group's pointer back-filled); with no hook
  configured, nothing but reports.

  Orphans — folders of a trashed or deleted group, reported, never moved:
  core's scan finds them by the deterministic name only (at the root or
  under a parent a hook named), so a folder named by the host hook
  (`News`) is reported here instead, for a trashed group, found through
  its pointer. A hard-deleted group's host-named folder cannot be traced —
  its pointer went with the row — and is not reported.

  What is publishing's own: a group is live until trashed, its pointer is
  `data["media_folder_uuid"]`, those host-named orphans, and one more
  report — `:unfiled`, a group whose posts use files still outside its
  folder, for which `PhoenixKit.Modules.Publishing.MediaAdoption` (`mix
  phoenix_kit_publishing.media.adopt --apply`) is the fix. The reorganizer
  moves folders only; it never files a file.
  """

  @behaviour PhoenixKit.Modules.Storage.Reorganizer.Source

  import Ecto.Query

  alias PhoenixKit.Modules.Publishing.MediaAdoption
  alias PhoenixKit.Modules.Publishing.MediaFolders
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.{Folder, FolderLink}
  alias PhoenixKit.Modules.Storage.Reorganizer.ResourceSource

  @source "publishing"

  @doc "The plan (`Reorganizer.Source.plan/2`); `opts` takes `:pending_days`."
  @impl true
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, opts \\ []), do: ResourceSource.plan(spec(), actor_uuid, opts)

  defp spec do
    %{
      source: @source,
      app: MediaFolders.app(),
      noun: "group",
      kinds: [
        %{
          kind: :group,
          schema: PublishingGroup,
          prefix: MediaFolders.folder_prefix(),
          pointer: MediaFolders.pointer(),
          live: &where(&1, [g], g.status != "trashed")
        }
      ],
      extra: &extra/2
    }
  end

  defp extra(actor_uuid, opts), do: host_named_orphans() ++ unfiled(actor_uuid, opts)

  # A trashed group's live folder whose name is not the deterministic one:
  # core's orphan scan goes by that name only, so it would never see it.
  defp host_named_orphans do
    folders =
      from(g in PublishingGroup,
        join: f in Folder,
        on: fragment("lower(?->>?)", g.data, ^pointer_key()) == type(f.uuid, :string),
        where: g.status == "trashed" and is_nil(f.trashed_at),
        order_by: [asc: g.inserted_at, asc: g.uuid],
        select: {g, f}
      )
      |> repo().all()
      |> Enum.reject(fn {group, folder} ->
        folder.name == MediaFolders.deterministic_name(group)
      end)

    counts = counts(Enum.map(folders, fn {_group, folder} -> folder.uuid end))

    Enum.map(folders, fn {group, folder} ->
      {files, _links} = folder_counts = Map.get(counts, folder.uuid, {0, 0})

      %{
        source: @source,
        kind: :orphan,
        op: :report,
        label: folder.name,
        folder: folder,
        counts: folder_counts,
        reason: "group #{group.name} (#{group.slug}) is trashed, #{files} file(s)"
      }
    end)
  end

  defp pointer_key, do: elem(MediaFolders.pointer(), 1)

  # `{files, links}` per folder, as the `Source` contract counts them: every
  # file row homed there (any status) and every link row.
  defp counts([]), do: %{}

  defp counts(folder_uuids) do
    files =
      from(f in StorageFile,
        where: f.folder_uuid in ^folder_uuids,
        group_by: f.folder_uuid,
        select: {f.folder_uuid, count()}
      )
      |> repo().all()
      |> Map.new()

    links =
      from(l in FolderLink,
        where: l.folder_uuid in ^folder_uuids,
        group_by: l.folder_uuid,
        select: {l.folder_uuid, count()}
      )
      |> repo().all()
      |> Map.new()

    Map.new(folder_uuids, &{&1, {Map.get(files, &1, 0), Map.get(links, &1, 0)}})
  end

  # A dry adoption plan: reads only, calls no hook.
  defp unfiled(actor_uuid, _opts) do
    case MediaAdoption.run(actor_uuid) do
      {:ok, %{groups: groups}} -> Enum.flat_map(groups, &unfiled_action/1)
      # Not opted in, or a hook that can't be called — which core's own
      # `:hook_error` report already names.
      {:error, _reason} -> []
    end
  end

  defp unfiled_action(%{adopt: [], link: []}), do: []

  defp unfiled_action(entry) do
    count = length(entry.adopt) + length(entry.link)

    [
      %{
        source: @source,
        kind: :unfiled,
        label: "group #{entry.name} (#{entry.slug})",
        op: :report,
        reason:
          "#{count} file(s) its posts use are outside its media folder " <>
            "(#{length(entry.adopt)} to adopt, #{length(entry.link)} to link) — run " <>
            "`mix phoenix_kit_publishing.media.adopt --apply` " <>
            "(or PhoenixKit.Modules.Publishing.MediaAdoption.run(actor_uuid, apply?: true))"
      }
    ]
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
