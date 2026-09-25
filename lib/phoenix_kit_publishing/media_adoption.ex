defmodule PhoenixKit.Modules.Publishing.MediaAdoption do
  @moduledoc """
  Files the media that posts already use into their group's folder — or,
  with post folders on, into each post's folder inside it — the one-time
  step after a host opts into `PhoenixKit.Modules.Publishing.MediaFolders`,
  safe to repeat.

      {:ok, report} = MediaAdoption.run(actor_uuid)               # dry run
      IO.puts(MediaAdoption.format_report(report))
      {:ok, report} = MediaAdoption.run(actor_uuid, apply?: true)

  (`mix phoenix_kit_publishing.media.adopt [--apply]` does the same.)

  Core's media reorganizer moves existing folders and never creates one or
  touches a file, so it cannot do this step; this uses core's per-record
  folder toolkit instead (`ResourceFolders.ensure/4` and `attach/2`).

  ## What belongs to a group, and to a post

  Every post of an active group, and each of its versions: version `data`
  `featured_image_uuid` and `audio_uuid`; content `data`
  `featured_image_uuid`, `featured_image_id` and `og.image_uuid`; and in
  the body, `file_uuid="…"` attributes and baked `/file/<uuid>/…` URLs. A
  uuid that names no stored file is counted as missing and otherwise
  ignored.

  Without post folders all of a group's posts file into the group folder
  (trashed posts too — they can come back). With them
  (`MediaFolders.post_folders?/0`) each live post files into its own
  folder, and a trashed post's files, where no live post of the group took
  them, into the group folder.

  ## What happens to a file

  Core's attach rule: a file with no home is adopted, a file homed
  elsewhere is linked and keeps its home. With post folders, a file homed
  in its group's own folder (filed there before post folders were on) is
  moved down into the post's folder. A file several posts or groups use is
  homed by the first — groups by `position`, `inserted_at`, uuid; posts by
  `inserted_at`, uuid — and linked into the others. Trashed,
  system-managed and other-library files are skipped. A group or post with
  nothing to file gets no folder.

  A post's folder found under ANOTHER group's folder (the post changed
  group) is moved under its own group's folder when applying; one a person
  put anywhere else is left where it is.

  A dry run reads (at most eight queries, whatever the number of posts),
  calls no hook and writes nothing, so it cannot know the name a folder not
  created yet will get. It does check that the configured hooks are
  callable: either run refuses with `{:error, {:bad_hooks, problems}}` when
  one is not. Applying calls the hooks (`MediaFolders.ensure_group_folder/3`
  and `ensure_post_folder/4`, strict) for each group and post with
  something to file; a hook that fails leaves it unfiled and says so,
  instead of creating its folder at the media root. A file's URL does not
  depend on its folder, so nothing anyone has published changes.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Publishing.MediaFolders
  alias PhoenixKit.Modules.Publishing.PublishingContent
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.PublishingVersion
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.{Folder, FolderLink, Libraries, ResourceFolders}

  @uuid "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
  # A PHK component's `file_uuid="…"` and a baked `…/file/<uuid>/…` URL.
  @body_refs "(?:file_uuid=[\"']|/file/)(#{@uuid})"

  @type entry :: %{
          kind: :group | :post,
          group_uuid: String.t(),
          group_name: String.t(),
          name: String.t(),
          slug: String.t(),
          group: PublishingGroup.t(),
          post: PublishingPost.t() | nil,
          folder: {:existing, Folder.t()} | :to_create,
          relocate: boolean(),
          adopt: [String.t()],
          link: [String.t()],
          rehome: [String.t()],
          in_place: non_neg_integer(),
          skipped: %{atom() => non_neg_integer()},
          result: map() | nil
        }

  @type report :: %{applied?: boolean(), entries: [entry()]}

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
      entries = plan()
      entries = if apply?, do: Enum.map(entries, &apply_entry(&1, actor_uuid)), else: entries

      {:ok, %{applied?: apply?, entries: entries}}
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
    posts = posts_of(groups)
    refs = references(Enum.map(posts, & &1.uuid))
    files = files(refs |> Map.values() |> Enum.concat() |> Enum.uniq())
    group_folders = current_group_folders(groups)
    post_mode? = MediaFolders.post_folders?()

    post_folders =
      if post_mode?,
        do: current_post_folders(for(p <- posts, is_nil(p.trashed_at), do: p.uuid)),
        else: %{}

    ctx = %{
      files: files,
      refs: refs,
      group_folders: group_folders,
      post_folders: post_folders,
      links: links(Map.values(group_folders) ++ Map.values(post_folders), Map.keys(files)),
      posts_by_group: Enum.group_by(posts, & &1.group_uuid),
      post_mode?: post_mode?
    }

    {entries, _homed} =
      Enum.flat_map_reduce(groups, MapSet.new(), fn group, homed ->
        plan_group(group, ctx, homed)
      end)

    entries
  end

  defp plan_group(group, %{post_mode?: false} = ctx, homed) do
    uuids = ctx.posts_by_group |> Map.get(group.uuid, []) |> post_refs(ctx)
    target(:group, group, nil, uuids, Map.get(ctx.group_folders, group.uuid), nil, ctx, homed)
  end

  defp plan_group(group, ctx, homed) do
    group_folder = Map.get(ctx.group_folders, group.uuid)
    rehome_from = group_folder && group_folder.uuid

    {live, trashed} =
      ctx.posts_by_group |> Map.get(group.uuid, []) |> Enum.split_with(&is_nil(&1.trashed_at))

    {post_entries, homed} =
      Enum.flat_map_reduce(live, homed, fn post, homed ->
        folder = Map.get(ctx.post_folders, post.uuid)
        target(:post, group, post, post_refs([post], ctx), folder, rehome_from, ctx, homed)
      end)

    placed = post_refs(live, ctx)
    leftover = post_refs(trashed, ctx) -- placed
    {group_entries, homed} = target(:group, group, nil, leftover, group_folder, nil, ctx, homed)

    {post_entries ++ group_entries, homed}
  end

  defp post_refs(posts, ctx),
    do: posts |> Enum.flat_map(&Map.get(ctx.refs, &1.uuid, [])) |> Enum.uniq()

  defp target(_kind, _group, _post, [], _folder, _rehome_from, _ctx, homed), do: {[], homed}

  defp target(kind, group, post, uuids, folder, rehome_from, ctx, homed) do
    library = if folder, do: folder.library_uuid, else: Libraries.media_uuid()

    {classified, homed} =
      uuids
      |> Enum.sort()
      |> Enum.map_reduce(homed, fn uuid, homed ->
        file = Map.get(ctx.files, uuid)
        verdict = classify(file, folder, library, ctx.links, homed, rehome_from)
        homes? = verdict in [:adopt, :rehome]
        {{verdict, uuid}, if(homes?, do: MapSet.put(homed, uuid), else: homed)}
      end)

    by_verdict = Enum.group_by(classified, &elem(&1, 0), &elem(&1, 1))

    entry = %{
      kind: kind,
      group_uuid: group.uuid,
      group_name: group.name,
      name: entry_name(group, post),
      slug: if(post, do: post.slug, else: group.slug),
      group: group,
      post: post,
      folder: if(folder, do: {:existing, folder}, else: :to_create),
      relocate: misplaced?(folder, group, ctx),
      adopt: Map.get(by_verdict, :adopt, []),
      link: Map.get(by_verdict, :link, []),
      rehome: Map.get(by_verdict, :rehome, []),
      in_place: length(Map.get(by_verdict, :in_place, [])),
      skipped:
        by_verdict
        |> Map.drop([:adopt, :link, :rehome, :in_place])
        |> Map.new(fn {reason, list} -> {reason, length(list)} end),
      result: nil
    }

    {[entry], homed}
  end

  defp entry_name(group, nil), do: group.name

  defp entry_name(group, post) do
    label =
      case MediaFolders.folder_name(post, nil) do
        {:ok, name} -> name
        nil -> MediaFolders.post_deterministic_name(post)
      end

    "#{group.name} / #{label}"
  end

  # A post folder sitting directly under ANOTHER group's folder: the post
  # changed group. One a person put anywhere else is theirs to place.
  defp misplaced?(nil, _group, _ctx), do: false

  defp misplaced?(%Folder{parent_uuid: parent_uuid}, group, ctx) do
    own = Map.get(ctx.group_folders, group.uuid)

    Enum.any?(ctx.group_folders, fn {group_uuid, folder} ->
      group_uuid != group.uuid and folder.uuid == parent_uuid
    end) and (is_nil(own) or own.uuid != parent_uuid)
  end

  defp classify(nil, _folder, _library, _links, _homed, _rehome_from), do: :missing
  defp classify(%{status: "trashed"}, _folder, _library, _links, _homed, _from), do: :trashed
  defp classify(%{system_managed: true}, _folder, _library, _links, _homed, _from), do: :system

  defp classify(file, folder, library, links, homed, rehome_from) do
    cond do
      to_string(file.library_uuid) != to_string(library) -> :other_library
      in_place?(file, folder, links) -> :in_place
      MapSet.member?(homed, file.uuid) -> :link
      true -> placement(file.folder_uuid, rehome_from)
    end
  end

  defp in_place?(_file, nil, _links), do: false

  defp in_place?(file, folder, links),
    do: file.folder_uuid == folder.uuid or Map.has_key?(links, {folder.uuid, file.uuid})

  # No home: adopted. Homed in the group's own folder, for a post folder:
  # moved down. Homed anywhere else: linked.
  defp placement(nil, _rehome_from), do: :adopt
  defp placement(home, home), do: :rehome
  defp placement(_home, _rehome_from), do: :link

  defp active_groups do
    from(g in PublishingGroup,
      where: g.status == "active",
      order_by: [asc: g.position, asc: g.inserted_at, asc: g.uuid]
    )
    |> repo().all()
  end

  defp posts_of([]), do: []

  defp posts_of(groups) do
    group_uuids = Enum.map(groups, & &1.uuid)

    from(p in PublishingPost,
      where: p.group_uuid in ^group_uuids,
      order_by: [asc: p.inserted_at, asc: p.uuid]
    )
    |> repo().all()
  end

  # `%{post_uuid => [file_uuid]}`: two queries, the body scanned by
  # Postgres so only the matched uuids leave the database.
  defp references([]), do: %{}

  defp references(post_uuids) do
    version_refs =
      from(v in PublishingVersion,
        where: v.post_uuid in ^post_uuids,
        select:
          {v.post_uuid,
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
        where: v.post_uuid in ^post_uuids,
        select:
          {v.post_uuid,
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
      |> Enum.map(fn {post_uuid, data_refs, body_refs} -> {post_uuid, data_refs ++ body_refs} end)

    (version_refs ++ content_refs)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {post_uuid, lists} ->
      {post_uuid, lists |> Enum.concat() |> Enum.flat_map(&cast/1) |> Enum.uniq()}
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

  # Each group's live pointed Media folder, one query.
  defp current_group_folders(groups) do
    groups
    |> Enum.flat_map(fn group ->
      case ResourceFolders.pointer_value(group, MediaFolders.pointer()) do
        nil -> []
        folder_uuid -> [{group.uuid, folder_uuid}]
      end
    end)
    |> resolve_pointers()
  end

  # Each live post's pointed Media folder: its versions' pointers, newest
  # version first, the first that names one (as `MediaFolders.post_folder/1`).
  defp current_post_folders([]), do: %{}

  defp current_post_folders(post_uuids) do
    key = elem(MediaFolders.pointer(), 1)

    from(v in PublishingVersion,
      where: v.post_uuid in ^post_uuids,
      where: not is_nil(fragment("?->>?", v.data, ^key)),
      order_by: [asc: v.post_uuid, desc: v.version_number],
      select: {v.post_uuid, fragment("?->>?", v.data, ^key)}
    )
    |> repo().all()
    |> Enum.flat_map(fn {post_uuid, pointer} ->
      Enum.map(cast(pointer), &{post_uuid, &1})
    end)
    |> resolve_pointers()
  end

  # `[{owner, folder_uuid}]` in preference order → `%{owner => folder}`,
  # keeping each owner's first pointer at a live Media folder. A pointer at
  # a folder outside Media is not the owner's folder: applying files into a
  # new one in Media (`MediaFolders` ignores it the same way).
  defp resolve_pointers([]), do: %{}

  defp resolve_pointers(pointers) do
    uuids = pointers |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    live =
      from(f in Folder,
        where: f.uuid in ^uuids and is_nil(f.trashed_at),
        where: f.library_uuid == ^Libraries.media_uuid()
      )
      |> repo().all()
      |> Map.new(&{&1.uuid, &1})

    Enum.reduce(pointers, %{}, fn {owner, folder_uuid}, acc ->
      case Map.get(live, folder_uuid) do
        nil -> acc
        folder -> Map.put_new(acc, owner, folder)
      end
    end)
  end

  # `%{{folder_uuid, file_uuid} => true}` for the links already in place.
  defp links([], _file_uuids), do: %{}
  defp links(_folders, []), do: %{}

  defp links(folders, file_uuids) do
    folder_uuids = folders |> Enum.map(& &1.uuid) |> Enum.uniq()

    from(l in FolderLink,
      where: l.folder_uuid in ^folder_uuids and l.file_uuid in ^file_uuids,
      select: {l.folder_uuid, l.file_uuid}
    )
    |> repo().all()
    |> Map.new(&{&1, true})
  end

  # ── Apply ──────────────────────────────────────────────────────────

  defp apply_entry(%{adopt: [], link: [], rehome: [], relocate: false} = entry, _actor),
    do: entry

  defp apply_entry(entry, actor_uuid) do
    case target_folder(entry, actor_uuid) do
      {:ok, folder, rehome_from, relocation} ->
        result =
          Enum.reduce(
            entry.rehome ++ entry.adopt ++ entry.link,
            %{
              folder_uuid: folder.uuid,
              relocated: relocation == :ok,
              rehomed: 0,
              adopted: 0,
              linked: 0,
              already: 0,
              failed: relocation_failures(relocation)
            },
            &tally(&2, &1, MediaFolders.file_into(&1, folder.uuid, rehome_from))
          )

        %{entry | result: %{result | failed: Enum.reverse(result.failed)}}

      {:error, reason} ->
        %{
          entry
          | result: %{
              folder_uuid: nil,
              relocated: false,
              rehomed: 0,
              adopted: 0,
              linked: 0,
              already: 0,
              failed: [{:folder, reason}]
            }
        }
    end
  end

  defp target_folder(%{kind: :group} = entry, actor_uuid) do
    with {:ok, folder} <- MediaFolders.ensure_group_folder(entry.group, actor_uuid, strict: true) do
      {:ok, folder, nil, :none}
    end
  end

  defp target_folder(%{kind: :post} = entry, actor_uuid) do
    with {:ok, group_folder} <-
           MediaFolders.ensure_group_folder(entry.group, actor_uuid, strict: true),
         {:ok, folder} <-
           MediaFolders.ensure_post_folder(entry.post, group_folder, actor_uuid, strict: true) do
      {:ok, folder, group_folder.uuid, relocate(entry, folder, group_folder)}
    end
  end

  defp relocate(%{relocate: true}, %Folder{parent_uuid: parent} = folder, %Folder{uuid: target})
       when parent != target do
    case Storage.update_folder(folder, %{parent_uuid: target}) do
      {:ok, _moved} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp relocate(_entry, _folder, _group_folder), do: :none

  defp relocation_failures({:error, reason}), do: [{:relocate, reason}]
  defp relocation_failures(_relocation), do: []

  defp tally(acc, _uuid, {:ok, :rehomed}), do: Map.update!(acc, :rehomed, &(&1 + 1))
  defp tally(acc, _uuid, {:ok, :adopted}), do: Map.update!(acc, :adopted, &(&1 + 1))
  defp tally(acc, _uuid, {:ok, :linked}), do: Map.update!(acc, :linked, &(&1 + 1))
  defp tally(acc, _uuid, {:ok, :already_attached}), do: Map.update!(acc, :already, &(&1 + 1))
  defp tally(acc, uuid, {:error, reason}), do: Map.update!(acc, :failed, &[{uuid, reason} | &1])

  # ── Report ─────────────────────────────────────────────────────────

  @doc "The report as text, one line per group and per post."
  @spec format_report(report()) :: String.t()
  def format_report(%{applied?: applied?, entries: entries}) do
    header =
      if applied?,
        do: "Publishing media adoption — applied",
        else: "Publishing media adoption — dry run, nothing written"

    lines =
      case entries do
        [] -> ["  no group has media to file"]
        entries -> Enum.map(entries, &format_entry/1)
      end

    Enum.join([header | lines], "\n")
  end

  defp format_entry(entry) do
    # A post's name already carries its slug (or date and time).
    title =
      if entry.kind == :post, do: "    #{entry.name}", else: "  #{entry.name} (#{entry.slug})"

    "#{title}: #{format_folder(entry)} — " <>
      "adopt #{length(entry.adopt)}, move down #{length(entry.rehome)}, " <>
      "link #{length(entry.link)}, in place #{entry.in_place}" <>
      format_skipped(entry.skipped) <> format_result(entry.result)
  end

  defp format_folder(%{folder: {:existing, folder}, relocate: true}),
    do: "folder #{inspect(folder.name)}, under another group's folder: to move"

  defp format_folder(%{folder: {:existing, folder}}), do: "folder #{inspect(folder.name)}"
  defp format_folder(%{folder: :to_create}), do: "folder to find or create"

  defp format_skipped(skipped) when map_size(skipped) == 0, do: ""

  defp format_skipped(skipped) do
    ", skipped " <> Enum.map_join(Enum.sort(skipped), ", ", fn {why, n} -> "#{n} #{why}" end)
  end

  defp format_result(nil), do: ""

  defp format_result(result) do
    moved = if result.relocated, do: "folder moved, ", else: ""

    " → #{moved}moved down #{result.rehomed}, adopted #{result.adopted}, " <>
      "linked #{result.linked}, already there #{result.already}" <>
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
