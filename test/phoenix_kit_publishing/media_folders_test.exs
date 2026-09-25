defmodule PhoenixKit.Modules.Publishing.MediaFoldersTest do
  use PhoenixKitPublishing.DataCase, async: false

  import PhoenixKitPublishing.Test.MediaFixtures

  alias PhoenixKit.Modules.Publishing.MediaFolders
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Folder

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

  defp live_folders_named(name) do
    Repo.all(from(f in Folder, where: f.name == ^name and is_nil(f.trashed_at)))
  end

  describe "enabled?/0" do
    test "is off until the host configures a parent hook" do
      refute MediaFolders.enabled?()

      configure_default_hooks()
      assert MediaFolders.enabled?()
    end
  end

  describe "module_folder/3 (the ready-made parent hook)" do
    test "creates one \"Publishing\" folder at the root and keeps answering it" do
      assert {:ok, uuid} = MediaFolders.module_folder(:group, nil, nil)
      assert {:ok, ^uuid} = MediaFolders.module_folder(:group, nil, nil)

      assert [%Folder{uuid: ^uuid, parent_uuid: nil}] = live_folders_named("Publishing")
    end

    test "follows its folder after someone renames and moves it" do
      {:ok, uuid} = MediaFolders.module_folder(:group, nil, nil)
      site = folder!("Site")

      {:ok, _} = Storage.update_folder(Repo.get!(Folder, uuid), %{name: "Публикации"})
      {:ok, _} = Storage.update_folder(Repo.get!(Folder, uuid), %{parent_uuid: site.uuid})

      assert {:ok, ^uuid} = MediaFolders.module_folder(:group, nil, nil)
      assert live_folders_named("Publishing") == []
    end

    test "makes a new one when its folder was trashed" do
      {:ok, uuid} = MediaFolders.module_folder(:group, nil, nil)
      {:ok, _} = Storage.trash_folder(Repo.get!(Folder, uuid))

      assert {:ok, new_uuid} = MediaFolders.module_folder(:group, nil, nil)
      assert new_uuid != uuid
      assert [%Folder{uuid: ^new_uuid}] = live_folders_named("Publishing")
    end
  end

  describe "group_folder_name/2 (the ready-made name hook)" do
    test "names the folder after the group" do
      assert MediaFolders.group_folder_name(group!("News"), nil) == {:ok, "News"}
    end

    test "has no name for anything that is not a saved group" do
      assert MediaFolders.group_folder_name(%{name: "News"}, nil) == nil
    end
  end

  describe "ensure_group_folder/2" do
    test "creates the group's folder under the module folder and points the group at it" do
      configure_default_hooks()
      group = group!("News")

      assert {:ok, %Folder{name: "News", parent_uuid: parent} = folder} =
               MediaFolders.ensure_group_folder(group, nil)

      assert [%Folder{uuid: ^parent}] = live_folders_named("Publishing")
      assert reload(group).data["media_folder_uuid"] == folder.uuid
    end

    test "keeps the pointed folder, whatever it is called now" do
      configure_default_hooks()
      group = group!("News")
      {:ok, folder} = MediaFolders.ensure_group_folder(group, nil)
      {:ok, _} = Storage.update_folder(folder, %{name: "Новости"})

      assert {:ok, %Folder{uuid: uuid, name: "Новости"}} =
               MediaFolders.ensure_group_folder(reload(group), nil)

      assert uuid == folder.uuid
    end

    test "leaves another group's same-named folder alone" do
      configure_default_hooks()
      first = group!("News")
      second = group!("News")

      {:ok, first_folder} = MediaFolders.ensure_group_folder(first, nil)
      {:ok, second_folder} = MediaFolders.ensure_group_folder(second, nil)

      assert second_folder.uuid != first_folder.uuid
      assert second_folder.name == "publishing-group-" <> second.uuid
    end

    test "without a name hook the folder gets the deterministic name" do
      Application.put_env(@app, :attachments_parent_folder, {MediaFolders, :module_folder})
      group = group!("News")

      assert {:ok, %Folder{name: name}} = MediaFolders.ensure_group_folder(group, nil)
      assert name == "publishing-group-" <> group.uuid
    end
  end

  describe "file_for_group/3" do
    test "does nothing on a host without a parent hook" do
      group = group!("News")
      file = file!()

      assert MediaFolders.file_for_group(group.slug, [file.uuid], nil) == :disabled
      assert reload(file).folder_uuid == nil
      assert live_folders_named("Publishing") == []
    end

    test "adopts a file with no home into the group's folder" do
      configure_default_hooks()
      group = group!("News")
      file = file!()

      assert MediaFolders.file_for_group(group.slug, [file.uuid], nil) == :ok

      folder_uuid = reload(group).data["media_folder_uuid"]
      assert reload(file).folder_uuid == folder_uuid
    end

    test "links a file homed elsewhere and leaves its home as it was" do
      configure_default_hooks()
      group = group!("News")
      elsewhere = folder!("Brand assets")
      file = file!(%{folder_uuid: elsewhere.uuid})

      assert MediaFolders.file_for_group(group.slug, [file.uuid], nil) == :ok

      folder_uuid = reload(group).data["media_folder_uuid"]
      assert reload(file).folder_uuid == elsewhere.uuid
      assert linked?(file, folder_uuid)
    end

    test "reports a file it cannot take instead of raising" do
      configure_default_hooks()
      group = group!("News")
      trashed = file!(%{status: "trashed", trashed_at: DateTime.utc_now(:second)})

      assert {:error, [{uuid, :file_trashed}]} =
               MediaFolders.file_for_group(group.slug, [trashed.uuid], nil)

      assert uuid == trashed.uuid
      assert reload(trashed).folder_uuid == nil
    end

    test "answers an unknown group without creating anything" do
      configure_default_hooks()

      assert MediaFolders.file_for_group("no-such-group", [file!().uuid], nil) ==
               {:error, :group_not_found}

      assert live_folders_named("Publishing") == []
    end
  end
end
