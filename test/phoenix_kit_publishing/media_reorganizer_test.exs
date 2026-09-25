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

  test "a host without hooks is only ever reported on" do
    group = group!("News")
    point(group, folder!("News"))

    assert Enum.all?(run(), &(&1.op == :report))
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
