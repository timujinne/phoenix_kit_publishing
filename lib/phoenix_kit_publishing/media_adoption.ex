defmodule PhoenixKit.Modules.Publishing.MediaAdoption do
  @moduledoc """
  Files the media that posts already use into their group's folder — the
  one-time step after a host opts into `PhoenixKit.Modules.Publishing.MediaFolders`,
  safe to repeat.

      {:ok, report} = MediaAdoption.run(actor_uuid)               # dry run
      IO.puts(MediaAdoption.format_report(report))
      {:ok, report} = MediaAdoption.run(actor_uuid, apply?: true)

  (`mix phoenix_kit_publishing.media.adopt [--apply]` does the same.)

  Core's media reorganizer moves existing folders and never creates one or
  touches a file, so it cannot do this step; this uses core's per-record
  folder toolkit instead (`ResourceFolders.ensure/4` and `attach/2`).

  ## What belongs to a group

  Every post of an active group — trashed posts too, they can come back —
  and each of its versions: version `data` `featured_image_uuid` and
  `audio_uuid`; content `data` `featured_image_uuid`, `featured_image_id`
  and `og.image_uuid`; and in the body, `file_uuid="…"` attributes and
  baked `/file/<uuid>/…` URLs. A uuid that names no stored file is counted
  as missing and otherwise ignored.

  ## What happens to a file

  Core's attach rule: a file with no home is adopted (its home becomes the
  group folder), a file homed elsewhere is linked and keeps its home. A
  file two groups use is homed by the first (groups by `position`,
  `inserted_at`, uuid) and linked into the others. Trashed, system-managed
  and other-library files are skipped. A group with nothing to file gets
  no folder.

  A dry run reads (six queries, whatever the number of posts), calls no
  hook and writes nothing, so it cannot know the name a folder not created
  yet will get. It does check that the configured hooks are callable:
  either run refuses with `{:error, {:bad_hooks, problems}}` when one is
  not. Applying calls the hooks (`MediaFolders.ensure_group_folder/3`,
  strict) for each group with something to file; a hook that fails leaves
  that group unfiled and says so, instead of creating its folder at the
  media root. A file's URL does not depend on its folder, so nothing anyone
  has published changes.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Publishing.MediaFolders
  alias PhoenixKit.Modules.Publishing.PublishingContent
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.PublishingVersion
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.{Folder, FolderLink, Libraries, ResourceFolders}

  @uuid "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
  # A PHK component's `file_uuid="…"` and a baked `…/file/<uuid>/…` URL.
  @body_refs "(?:file_uuid=[\"']|/file/)(#{@uuid})"

  @type entry :: %{
          group_uuid: String.t(),
          name: String.t(),
          slug: String.t(),
          group: PublishingGroup.t(),
          folder: {:existing, Folder.t()} | :to_create,
          adopt: [String.t()],
          link: [String.t()],
          in_place: non_neg_integer(),
          skipped: %{atom() => non_neg_integer()},
          result: map() | nil
        }

  @type report :: %{applied?: boolean(), groups: [entry()]}

  @doc """
  Plans (and with `apply?: true` applies) the filing of every active
  group's media. `{:error, :not_configured}` on a host without the parent
  hook — there is no folder to file into; `{:error, {:bad_hooks, problems}}`
  when a configured hook is not callable (`MediaFolders.hook_problems/0`).
  """
  @spec run(String.t() | nil, keyword()) ::
          {:ok, report()} | {:error, :not_configured | {:bad_hooks, [String.t()]}}
  def run(actor_uuid, opts \\ []) do
    with :ok <- check_config() do
      apply? = Keyword.get(opts, :apply?, false)
      groups = plan()
      groups = if apply?, do: Enum.map(groups, &apply_entry(&1, actor_uuid)), else: groups

      {:ok, %{applied?: apply?, groups: groups}}
    end
  end

  defp check_config do
    case {MediaFolders.enabled?(), MediaFolders.hook_problems()} do
      {false, _problems} -> {:error, :not_configured}
      {true, []} -> :ok
      {true, problems} -> {:error, {:bad_hooks, problems}}
    end
  end

  # ── Plan ───────────────────────────────────────────────────────────

  defp plan do
    groups = active_groups()
    refs = references(Enum.map(groups, & &1.uuid))
    files = files(refs |> Map.values() |> Enum.concat() |> Enum.uniq())
    folders = current_folders(groups)
    links = links(Map.values(folders), Map.keys(files))

    {entries, _homed} =
      Enum.flat_map_reduce(groups, MapSet.new(), fn group, homed ->
        case Map.get(refs, group.uuid, []) do
          [] -> {[], homed}
          uuids -> plan_group(group, uuids, files, Map.get(folders, group.uuid), links, homed)
        end
      end)

    entries
  end

  defp plan_group(group, uuids, files, folder, links, homed) do
    library = if folder, do: folder.library_uuid, else: Libraries.media_uuid()

    {classified, homed} =
      uuids
      |> Enum.sort()
      |> Enum.map_reduce(homed, fn uuid, homed ->
        verdict = classify(Map.get(files, uuid), folder, library, links, homed)
        {{verdict, uuid}, if(verdict == :adopt, do: MapSet.put(homed, uuid), else: homed)}
      end)

    by_verdict = Enum.group_by(classified, &elem(&1, 0), &elem(&1, 1))

    entry = %{
      group_uuid: group.uuid,
      name: group.name,
      slug: group.slug,
      group: group,
      folder: if(folder, do: {:existing, folder}, else: :to_create),
      adopt: Map.get(by_verdict, :adopt, []),
      link: Map.get(by_verdict, :link, []),
      in_place: length(Map.get(by_verdict, :in_place, [])),
      skipped:
        by_verdict
        |> Map.drop([:adopt, :link, :in_place])
        |> Map.new(fn {reason, list} -> {reason, length(list)} end),
      result: nil
    }

    {[entry], homed}
  end

  defp classify(nil, _folder, _library, _links, _homed), do: :missing
  defp classify(%{status: "trashed"}, _folder, _library, _links, _homed), do: :trashed
  defp classify(%{system_managed: true}, _folder, _library, _links, _homed), do: :system

  defp classify(file, folder, library, links, homed) do
    cond do
      to_string(file.library_uuid) != to_string(library) -> :other_library
      folder && file.folder_uuid == folder.uuid -> :in_place
      folder && Map.has_key?(links, {folder.uuid, file.uuid}) -> :in_place
      is_nil(file.folder_uuid) and not MapSet.member?(homed, file.uuid) -> :adopt
      true -> :link
    end
  end

  defp active_groups do
    from(g in PublishingGroup,
      where: g.status == "active",
      order_by: [asc: g.position, asc: g.inserted_at, asc: g.uuid]
    )
    |> repo().all()
  end

  # `%{group_uuid => [file_uuid]}`: two queries, the body scanned by
  # Postgres so only the matched uuids leave the database.
  defp references([]), do: %{}

  defp references(group_uuids) do
    version_refs =
      from(v in PublishingVersion,
        join: p in PublishingPost,
        on: p.uuid == v.post_uuid,
        where: p.group_uuid in ^group_uuids,
        select:
          {p.group_uuid,
           [
             fragment("?->>'featured_image_uuid'", v.data),
             fragment("?->>'audio_uuid'", v.data)
           ]}
      )
      |> repo().all()

    content_refs =
      from(c in PublishingContent,
        join: v in PublishingVersion,
        on: v.uuid == c.version_uuid,
        join: p in PublishingPost,
        on: p.uuid == v.post_uuid,
        where: p.group_uuid in ^group_uuids,
        select:
          {p.group_uuid,
           [
             fragment("?->>'featured_image_uuid'", c.data),
             fragment("?->>'featured_image_id'", c.data),
             fragment("?->'og'->>'image_uuid'", c.data)
           ],
           fragment(
             "ARRAY(SELECT m[1] FROM regexp_matches(coalesce(?, ''), ?, 'g') AS m)",
             c.content,
             ^@body_refs
           )}
      )
      |> repo().all()
      |> Enum.map(fn {group_uuid, data_refs, body_refs} ->
        {group_uuid, data_refs ++ body_refs}
      end)

    (version_refs ++ content_refs)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {group_uuid, lists} ->
      {group_uuid, lists |> Enum.concat() |> Enum.flat_map(&cast/1) |> Enum.uniq()}
    end)
  end

  defp files([]), do: %{}

  defp files(uuids) do
    from(f in StorageFile,
      where: f.uuid in ^uuids,
      select: map(f, [:uuid, :folder_uuid, :status, :system_managed, :library_uuid])
    )
    |> repo().all()
    |> Map.new(&{&1.uuid, &1})
  end

  # Each group's live pointed folder, one query.
  defp current_folders(groups) do
    pointers =
      groups
      |> Enum.flat_map(fn group ->
        case ResourceFolders.pointer_value(group, MediaFolders.pointer()) do
          nil -> []
          folder_uuid -> [{group.uuid, folder_uuid}]
        end
      end)

    live =
      case pointers do
        [] ->
          %{}

        _ ->
          uuids = Enum.map(pointers, &elem(&1, 1))

          # A pointer at a folder outside Media is not the group's folder:
          # applying files into a new one in Media (`ensure_group_folder/3`
          # ignores it the same way).
          from(f in Folder,
            where: f.uuid in ^uuids and is_nil(f.trashed_at),
            where: f.library_uuid == ^Libraries.media_uuid()
          )
          |> repo().all()
          |> Map.new(&{&1.uuid, &1})
      end

    Enum.reduce(pointers, %{}, fn {group_uuid, folder_uuid}, acc ->
      case Map.get(live, folder_uuid) do
        nil -> acc
        folder -> Map.put(acc, group_uuid, folder)
      end
    end)
  end

  # `%{{folder_uuid, file_uuid} => true}` for the links already in place.
  defp links([], _file_uuids), do: %{}
  defp links(_folders, []), do: %{}

  defp links(folders, file_uuids) do
    folder_uuids = Enum.map(folders, & &1.uuid)

    from(l in FolderLink,
      where: l.folder_uuid in ^folder_uuids and l.file_uuid in ^file_uuids,
      select: {l.folder_uuid, l.file_uuid}
    )
    |> repo().all()
    |> Map.new(&{&1, true})
  end

  # ── Apply ──────────────────────────────────────────────────────────

  defp apply_entry(%{adopt: [], link: []} = entry, _actor_uuid), do: entry

  defp apply_entry(entry, actor_uuid) do
    case MediaFolders.ensure_group_folder(entry.group, actor_uuid, strict: true) do
      {:ok, folder} ->
        result =
          Enum.reduce(
            entry.adopt ++ entry.link,
            %{folder_uuid: folder.uuid, adopted: 0, linked: 0, already: 0, failed: []},
            &tally(&2, &1, ResourceFolders.attach(&1, folder.uuid))
          )

        %{entry | result: %{result | failed: Enum.reverse(result.failed)}}

      {:error, reason} ->
        %{
          entry
          | result: %{
              folder_uuid: nil,
              adopted: 0,
              linked: 0,
              already: 0,
              failed: [{:folder, reason}]
            }
        }
    end
  end

  defp tally(acc, _uuid, {:ok, :adopted}), do: Map.update!(acc, :adopted, &(&1 + 1))
  defp tally(acc, _uuid, {:ok, :linked}), do: Map.update!(acc, :linked, &(&1 + 1))
  defp tally(acc, _uuid, {:ok, :already_attached}), do: Map.update!(acc, :already, &(&1 + 1))
  defp tally(acc, uuid, {:error, reason}), do: Map.update!(acc, :failed, &[{uuid, reason} | &1])

  # ── Report ─────────────────────────────────────────────────────────

  @doc "The report as text, one line per group."
  @spec format_report(report()) :: String.t()
  def format_report(%{applied?: applied?, groups: groups}) do
    header =
      if applied?,
        do: "Publishing media adoption — applied",
        else: "Publishing media adoption — dry run, nothing written"

    lines =
      case groups do
        [] -> ["  no group has media to file"]
        groups -> Enum.map(groups, &format_entry/1)
      end

    Enum.join([header | lines], "\n")
  end

  defp format_entry(entry) do
    "  #{entry.name} (#{entry.slug}): #{format_folder(entry.folder)} — " <>
      "adopt #{length(entry.adopt)}, link #{length(entry.link)}, in place #{entry.in_place}" <>
      format_skipped(entry.skipped) <> format_result(entry.result)
  end

  defp format_folder({:existing, folder}), do: "folder #{inspect(folder.name)}"
  defp format_folder(:to_create), do: "folder to find or create"

  defp format_skipped(skipped) when map_size(skipped) == 0, do: ""

  defp format_skipped(skipped) do
    ", skipped " <> Enum.map_join(Enum.sort(skipped), ", ", fn {why, n} -> "#{n} #{why}" end)
  end

  defp format_result(nil), do: ""

  defp format_result(result) do
    " → adopted #{result.adopted}, linked #{result.linked}, already there #{result.already}" <>
      format_failures(result.failed)
  end

  defp format_failures([]), do: ""

  defp format_failures(failed) do
    ", failed " <>
      Enum.map_join(failed, ", ", fn
        {:folder, {hook, reason}} when hook in [:parent_hook, :name_hook] ->
          "folder not created, #{hook} failed: #{ResourceFolders.describe_failure(reason)}"

        {what, reason} ->
          "#{what}: #{ResourceFolders.describe_failure(reason)}"
      end)
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp cast(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} when byte_size(value) == 36 -> [String.downcase(uuid)]
      _ -> []
    end
  end

  defp cast(_value), do: []

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
