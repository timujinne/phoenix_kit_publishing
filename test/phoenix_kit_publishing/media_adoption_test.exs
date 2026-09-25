defmodule PhoenixKit.Modules.Publishing.MediaAdoptionTest do
  use PhoenixKitPublishing.DataCase, async: false

  import PhoenixKitPublishing.Test.MediaFixtures

  alias PhoenixKit.Modules.Publishing.MediaAdoption
  alias PhoenixKit.Modules.Publishing.MediaFolders
  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKit.Modules.Storage.FolderLink

  @app :phoenix_kit_publishing

  setup do
    Application.put_env(@app, :attachments_parent_folder, {MediaFolders, :module_folder})
    Application.put_env(@app, :attachments_folder_name, {MediaFolders, :folder_name})

    on_exit(fn ->
      Application.delete_env(@app, :attachments_parent_folder)
      Application.delete_env(@app, :attachments_folder_name)
    end)
  end

  defp entry(report, group),
    do: Enum.find(report.entries, &(&1.kind == :group and &1.group_uuid == group.uuid))

  defp group_folder(group), do: Repo.get!(Folder, reload(group).data["media_folder_uuid"])

  defp folder_count, do: Repo.aggregate(Folder, :count)

  describe "run/2 on a host that has not opted in" do
    test "refuses, and writes nothing" do
      Application.delete_env(@app, :attachments_parent_folder)
      post!(group!("News"), version_data: %{"featured_image_uuid" => file!().uuid})

      assert MediaAdoption.run(nil, apply?: true) == {:error, :not_configured}
      assert folder_count() == 0
    end
  end

  describe "which files belong to a group" do
    test "every place a post keeps a file" do
      group = group!("News")
      [featured, audio, localized, legacy, og, component, baked] = for _ <- 1..7, do: file!()

      body = """
      Intro.

      <Image file_uuid="#{component.uuid}" alt="x"/>

      ![chart](/phoenix_kit/file/#{String.upcase(baked.uuid)}/large/ab12)
      """

      post!(group,
        version_data: %{"featured_image_uuid" => featured.uuid, "audio_uuid" => audio.uuid},
        contents: [
          {"en", body,
           %{
             "featured_image_uuid" => localized.uuid,
             "featured_image_id" => legacy.uuid,
             "og" => %{"image_uuid" => og.uuid}
           }}
        ]
      )

      {:ok, report} = MediaAdoption.run(nil)

      expected =
        Enum.sort(Enum.map([featured, audio, localized, legacy, og, component, baked], & &1.uuid))

      assert Enum.sort(entry(report, group).adopt) == expected
    end

    test "trashed posts count, trashed groups and unknown uuids do not" do
      news = group!("News")
      old = group!("Old", %{status: "trashed"})
      of_trashed_post = file!()
      of_trashed_group = file!()

      post!(news,
        trashed_at: DateTime.utc_now(:second),
        version_data: %{"featured_image_uuid" => of_trashed_post.uuid},
        contents: [{"en", ~s(<Image file_uuid="#{Ecto.UUID.generate()}"/>), %{}}]
      )

      post!(old, version_data: %{"featured_image_uuid" => of_trashed_group.uuid})

      {:ok, report} = MediaAdoption.run(nil)

      assert entry(report, news).adopt == [of_trashed_post.uuid]
      assert entry(report, old) == nil
    end
  end

  describe "a dry run" do
    test "plans without writing anything" do
      group = group!("News")
      loose = file!()
      elsewhere = folder!("Brand assets")
      homed = file!(%{folder_uuid: elsewhere.uuid})

      post!(group,
        version_data: %{"featured_image_uuid" => loose.uuid},
        contents: [{"en", ~s(<Image file_uuid="#{homed.uuid}"/>), %{}}]
      )

      folders_before = folder_count()

      assert {:ok, %{applied?: false} = report} = MediaAdoption.run(nil)

      assert %{adopt: [loose_uuid], link: [homed_uuid], folder: :to_create} =
               entry(report, group)

      assert {loose_uuid, homed_uuid} == {loose.uuid, homed.uuid}
      assert folder_count() == folders_before
      assert reload(loose).folder_uuid == nil
      assert Repo.aggregate(FolderLink, :count) == 0
      assert reload(group).data["media_folder_uuid"] == nil
    end
  end

  describe "applying" do
    test "files a group's media into Publishing/<group>" do
      group = group!("News")
      loose = file!()
      elsewhere = folder!("Brand assets")
      homed = file!(%{folder_uuid: elsewhere.uuid})

      post!(group,
        version_data: %{"featured_image_uuid" => loose.uuid},
        contents: [{"en", ~s(<Image file_uuid="#{homed.uuid}"/>), %{}}]
      )

      assert {:ok, %{applied?: true} = report} = MediaAdoption.run(nil, apply?: true)
      assert %{adopted: 1, linked: 1, failed: []} = entry(report, group).result

      folder = group_folder(group)
      parent = Repo.get!(Folder, folder.parent_uuid)
      assert {parent.name, parent.parent_uuid, folder.name} == {"Publishing", nil, "News"}

      assert reload(loose).folder_uuid == folder.uuid
      assert reload(homed).folder_uuid == elsewhere.uuid
      assert linked?(homed, folder.uuid)
    end

    test "a file two groups use is homed by the first and linked into the second" do
      first = group!("News", %{position: 1})
      second = group!("Legal", %{position: 2})
      shared = file!()

      post!(second, version_data: %{"featured_image_uuid" => shared.uuid})
      post!(first, version_data: %{"featured_image_uuid" => shared.uuid})

      {:ok, dry} = MediaAdoption.run(nil)
      assert entry(dry, first).adopt == [shared.uuid]
      assert entry(dry, second).link == [shared.uuid]

      {:ok, _} = MediaAdoption.run(nil, apply?: true)

      assert reload(shared).folder_uuid == group_folder(first).uuid
      assert linked?(shared, group_folder(second).uuid)
    end

    test "a group with nothing to file gets no folder" do
      empty = group!("Legal")
      post!(empty, contents: [{"en", "No pictures here.", %{}}])

      {:ok, report} = MediaAdoption.run(nil, apply?: true)

      assert entry(report, empty) == nil
      assert folder_count() == 0
    end

    test "leaves trashed files alone and says so" do
      group = group!("News")
      trashed = file!(%{status: "trashed", trashed_at: DateTime.utc_now(:second)})
      post!(group, version_data: %{"featured_image_uuid" => trashed.uuid})

      {:ok, report} = MediaAdoption.run(nil, apply?: true)

      assert %{adopt: [], link: [], skipped: %{trashed: 1}} = entry(report, group)
      assert reload(trashed).folder_uuid == nil
    end

    test "a second run has nothing left to do" do
      group = group!("News")
      file = file!()
      post!(group, version_data: %{"featured_image_uuid" => file.uuid})

      {:ok, _} = MediaAdoption.run(nil, apply?: true)
      folders_after_first = folder_count()
      {:ok, report} = MediaAdoption.run(nil, apply?: true)

      assert %{adopt: [], link: [], in_place: 1, folder: {:existing, _}} = entry(report, group)
      assert folder_count() == folders_after_first
    end

    test "changes nothing about a file but its folder, so its URLs stay as they were" do
      group = group!("News")
      file = file!()
      instance = file_instance!(file)
      post!(group, contents: [{"en", "![x](/file/#{file.uuid}/large/abcd)", %{}}])

      # A file URL is built from the file's uuid and variant (the token signs
      # exactly those), and served from the instance row's stored object.
      drop = [:__meta__, :folder_uuid, :updated_at]
      before = file |> reload() |> Map.from_struct() |> Map.drop(drop)

      {:ok, _} = MediaAdoption.run(nil, apply?: true)

      after_file = reload(file)
      assert after_file.folder_uuid == group_folder(group).uuid
      assert after_file |> Map.from_struct() |> Map.drop(drop) == before
      assert Repo.reload!(instance) == instance
    end

    test "skips system-managed files and files of another library" do
      group = group!("News")
      managed = file!(%{system_managed: true})
      private = file!(%{library_uuid: library!().uuid})

      post!(group,
        version_data: %{"featured_image_uuid" => managed.uuid},
        contents: [{"en", ~s(<Image file_uuid="#{private.uuid}"/>), %{}}]
      )

      {:ok, report} = MediaAdoption.run(nil, apply?: true)

      assert %{adopt: [], link: [], skipped: %{system: 1, other_library: 1}} =
               entry(report, group)

      assert reload(managed).folder_uuid == nil
      assert reload(private).folder_uuid == nil
    end

    test "a pointer at a folder outside Media is not the group's folder" do
      theirs = folder!("News", nil, %{library_uuid: library!().uuid})
      group = group!("News", %{data: %{"media_folder_uuid" => theirs.uuid}})
      file = file!()
      post!(group, version_data: %{"featured_image_uuid" => file.uuid})

      {:ok, dry} = MediaAdoption.run(nil)
      assert %{folder: :to_create, adopt: [_]} = entry(dry, group)

      {:ok, _} = MediaAdoption.run(nil, apply?: true)

      folder = group_folder(group)
      assert folder.uuid != theirs.uuid
      assert reload(file).folder_uuid == folder.uuid
    end

    test "a hook that fails on apply leaves the group unfiled instead of using the root" do
      Application.put_env(
        @app,
        :attachments_parent_folder,
        {PhoenixKitPublishing.Test.MediaHooks, :boom}
      )

      group = group!("News")
      file = file!()
      post!(group, version_data: %{"featured_image_uuid" => file.uuid})

      {:ok, report} = MediaAdoption.run(nil, apply?: true)

      assert %{failed: [{:folder, {:parent_hook, _}}]} = entry(report, group).result
      assert MediaAdoption.format_report(report) =~ "parent_hook failed"
      assert folder_count() == 0
      assert reload(file).folder_uuid == nil
    end
  end

  describe "run/2 with a hook that cannot be called" do
    test "refuses before planning, dry run included" do
      Application.put_env(@app, :attachments_folder_name, {MediaFolders, :no_such_hook})
      post!(group!("News"), version_data: %{"featured_image_uuid" => file!().uuid})

      assert {:error, {:bad_hooks, [problem]}} = MediaAdoption.run(nil)
      assert problem =~ "attachments_folder_name"
      assert {:error, {:bad_hooks, _}} = MediaAdoption.run(nil, apply?: true)
      assert folder_count() == 0
    end
  end

  describe "format_report/1" do
    test "lists each group's plan" do
      group = group!("News")
      post!(group, version_data: %{"featured_image_uuid" => file!().uuid})

      {:ok, report} = MediaAdoption.run(nil)
      text = MediaAdoption.format_report(report)

      assert text =~ "News"
      assert text =~ "adopt 1"
      assert text =~ "dry run"
    end
  end
end
