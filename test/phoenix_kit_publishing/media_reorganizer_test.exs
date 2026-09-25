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
    Application.put_env(@app, :attachments_folder_name, {MediaFolders, :group_folder_name})
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
    configure_default_hooks()

    actions = run(apply?: true)

    assert Enum.any?(actions, &(&1.op == :report and &1.kind == :orphan))
    assert reload(orphan).parent_uuid == nil
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
