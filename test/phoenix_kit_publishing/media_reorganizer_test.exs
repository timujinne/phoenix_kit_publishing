defmodule PhoenixKit.Modules.Publishing.MediaReorganizerTest do
  use PhoenixKitPublishing.DataCase, async: false

  import PhoenixKitPublishing.Test.MediaFixtures

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.MediaFolders
  alias PhoenixKit.Modules.Publishing.MediaReorganizer
  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKit.Modules.Storage.Reorganizer

  @app :phoenix_kit_publishing

  setup do
    on_exit(fn ->
      Application.delete_env(@app, :attachments_parent_folder)
      Application.delete_env(@app, :attachments_folder_name)
    end)
  end

  defp configure_default_hooks do
    Application.put_env(@app, :attachments_parent_folder, {MediaFolders, :module_folder})
    Application.put_env(@app, :attachments_folder_name, {MediaFolders, :folder_name})
  end

  defp run(opts \\ []) do
    {:ok, report} = Reorganizer.run(nil, Keyword.merge([sources: [MediaReorganizer]], opts))
    report.actions
  end

  defp point(group, folder) do
    {:ok, updated} =
      DBStorage.update_group(group, %{
        data: Map.put(group.data, "media_folder_uuid", folder.uuid)
      })

    updated
  end

  test "a host without hooks is only ever reported on, and nothing moves" do
    news = group!("News")
    news_folder = folder!("News")
    point(news, news_folder)
    legal = group!("Legal")
    legacy = folder!("publishing-group-" <> legal.uuid)
    old = group!("Old", %{status: "trashed"})
    orphan = folder!("publishing-group-" <> old.uuid)

    planned = run()

    # Something is planned — the orphan — so "all reports" is not vacuous.
    assert [%{op: :report, kind: :orphan, folder: %{uuid: orphan_uuid}}] = planned
    assert orphan_uuid == orphan.uuid

    run(apply?: true)

    for folder <- [news_folder, legacy, orphan] do
      assert Map.take(reload(folder), [:name, :parent_uuid, :trashed_at]) ==
               Map.take(folder, [:name, :parent_uuid, :trashed_at])
    end

    assert reload(legal).data["media_folder_uuid"] == nil
  end

  test "moves a group's folder under the parent the hook now answers" do
    group = group!("News")
    folder = folder!("News")
    point(group, folder)
    configure_default_hooks()

    assert [%{op: :move, kind: :group, name: nil}] = run()

    run(apply?: true)

    moved = reload(folder)
    assert Repo.get!(Folder, moved.parent_uuid).name == "Publishing"
    assert moved.name == "News"
  end

  test "adopts a folder found by its deterministic name and back-fills the pointer" do
    group = group!("News")
    legacy = folder!("publishing-group-" <> group.uuid)
    configure_default_hooks()

    assert [%{op: :move, name: "News"}] = run()

    run(apply?: true)

    assert reload(group).data["media_folder_uuid"] == legacy.uuid
    assert %Folder{name: "News", parent_uuid: parent} = reload(legacy)
    assert Repo.get!(Folder, parent).name == "Publishing"
  end

  test "a trashed group's folder is an orphan, reported and left in place" do
    group = group!("Old", %{status: "trashed"})
    orphan = folder!("publishing-group-" <> group.uuid)
    # Pointed at too: core's scan and the pointer both find it; one report.
    point(group, orphan)
    configure_default_hooks()

    actions = run(apply?: true)

    assert [%{op: :report, kind: :orphan}] = actions
    assert reload(orphan).parent_uuid == nil
  end

  test "a trashed group's folder that core's scan can't see is reported, once" do
    configure_default_hooks()
    {:ok, parent_uuid} = MediaFolders.module_folder(:group, nil, nil)
    group = group!("Old", %{status: "trashed"})
    folder = folder!("publishing-group-" <> group.uuid, parent_uuid)
    point(group, folder)

    # No live group has a folder, so no hook names `Publishing` as a parent
    # and core's scan stays at the root.
    assert [%{op: :report, kind: :orphan, folder: %{uuid: uuid}}] = run(apply?: true)
    assert uuid == folder.uuid
    assert reload(folder).parent_uuid == parent_uuid
  end

  test "a trashed group's pointer at another library's folder or at a live group's folder is no orphan" do
    configure_default_hooks()
    private = folder!("Old", nil, %{library_uuid: library!().uuid})
    point(group!("Old", %{status: "trashed"}), private)

    shared = folder!("Shared")
    point(group!("Live"), shared)
    point(group!("Gone", %{status: "trashed"}), shared)

    refute Enum.any?(run(), &(&1.kind == :orphan))
  end

  test "a folder two trashed groups point at is reported once" do
    configure_default_hooks()
    shared = folder!("Shared")
    point(group!("Older", %{status: "trashed"}), shared)
    point(group!("Newer", %{status: "trashed"}), shared)

    assert [%{kind: :orphan, folder: %{uuid: uuid}, reason: reason}] = run()
    assert uuid == shared.uuid
    assert reason =~ "group Older"
  end

  test "a broken name hook core already reported is not reported twice" do
    Application.put_env(@app, :attachments_parent_folder, {MediaFolders, :module_folder})
    Application.put_env(@app, :attachments_folder_name, {MediaFolders, :no_such_hook})
    group = group!("News")
    folder!("publishing-group-" <> group.uuid)

    assert [%{kind: :hook_error, label: "attachments folder-name hook"}] =
             Enum.filter(run(), &(&1.kind == :hook_error))
  end

  test "a broken name hook says nothing on a host that has not opted in" do
    Application.put_env(@app, :attachments_folder_name, {MediaFolders, :no_such_hook})

    assert run() == []
  end

  test "a name hook that can't be called is reported even with nothing to move" do
    Application.put_env(@app, :attachments_parent_folder, {MediaFolders, :module_folder})
    Application.put_env(@app, :attachments_folder_name, {MediaFolders, :no_such_hook})

    assert [%{op: :report, kind: :hook_error, reason: reason}] = run()
    assert reason =~ "attachments_folder_name"
  end

  test "a trashed group's host-named folder is reported once, through its pointer" do
    configure_default_hooks()
    group = group!("News")
    {:ok, folder} = MediaFolders.ensure_group_folder(group, nil)
    file!(%{folder_uuid: folder.uuid})
    {:ok, _} = DBStorage.trash_group(reload(group))

    assert [%{op: :report, kind: :orphan, label: "News", counts: {1, 0}, reason: reason}] =
             run(apply?: true)

    assert reason =~ "trashed"
    assert reload(folder).trashed_at == nil
  end

  test "reports a group whose posts use files outside its folder" do
    configure_default_hooks()
    group = group!("News")
    post!(group, version_data: %{"featured_image_uuid" => file!().uuid})

    assert [%{op: :report, kind: :unfiled, reason: reason}] = run()
    assert reason =~ "1 file(s)"
    assert reason =~ "mix phoenix_kit_publishing.media.adopt --apply"
  end

  test "says nothing about unfiled media on a host that has not opted in" do
    post!(group!("News"), version_data: %{"featured_image_uuid" => file!().uuid})

    assert run() == []
  end
end
