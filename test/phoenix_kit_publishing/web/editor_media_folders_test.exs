defmodule PhoenixKit.Modules.Publishing.Web.EditorMediaFoldersTest do
  @moduledoc """
  A file chosen in the editor's media picker lands in the post's group
  folder — on a host that opted into group media folders — and stays
  exactly where it was on one that did not, or when the choice is refused.

  The filing runs in a task under `PhoenixKit.TaskSupervisor`, so the
  positive cases wait for it (`eventually/1`); the negative ones start no
  task at all, and are checked after a positive choice in the same group
  has been filed.
  """

  use PhoenixKitPublishing.LiveCase, async: false

  import PhoenixKitPublishing.Test.MediaFixtures

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.MediaFolders
  alias PhoenixKit.Modules.Publishing.Posts

  @app :phoenix_kit_publishing

  setup do
    slug = "mediafolders-#{System.unique_integer([:positive])}"
    {:ok, _} = Groups.add_group(slug, mode: "slug")
    {:ok, post} = Posts.create_post(slug, %{title: "P", slug: "p", content: "Body"})

    on_exit(fn ->
      Application.delete_env(@app, :attachments_parent_folder)
      Application.delete_env(@app, :attachments_folder_name)
    end)

    %{slug: slug, post: post}
  end

  defp opt_in do
    Application.put_env(@app, :attachments_parent_folder, {MediaFolders, :module_folder})
    Application.put_env(@app, :attachments_folder_name, {MediaFolders, :folder_name})
  end

  defp open_editor(conn, slug, post) do
    user = user!()

    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope(user_uuid: user.uuid, email: user.email))
      |> live("/admin/publishing/#{slug}/#{post[:uuid]}/edit")

    view
  end

  defp choose(view, file_uuids) do
    send(view.pid, {:media_selected, file_uuids})
    render(view)
  end

  defp group_folder_uuid(slug), do: DBStorage.get_group_by_slug(slug).data["media_folder_uuid"]

  # Polls until `fun` stops failing (the filing task has committed), for up
  # to two seconds.
  defp eventually(fun, tries \\ 40) do
    fun.()
  rescue
    error in [ExUnit.AssertionError] ->
      if tries > 0 do
        Process.sleep(50)
        eventually(fun, tries - 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp assert_filed(file, slug) do
    eventually(fn ->
      folder_uuid = group_folder_uuid(slug)
      assert is_binary(folder_uuid)
      assert reload(file).folder_uuid == folder_uuid
    end)
  end

  defp audio_file!, do: file!(%{file_type: "audio", mime_type: "audio/mpeg", ext: "mp3"})

  describe "on a host that opted in" do
    setup do
      opt_in()
      :ok
    end

    test "a featured image lands in the group's folder", %{conn: conn, slug: slug, post: post} do
      file = file!()
      view = open_editor(conn, slug, post)

      render_click(view, "open_media_selector", %{"field" => "featured_image_uuid"})
      choose(view, [file.uuid])

      assert_filed(file, slug)
    end

    test "with post folders on, a pick lands in the post's folder inside the group's",
         %{conn: conn, slug: slug, post: post} do
      Application.put_env(@app, :post_media_folders, true)
      on_exit(fn -> Application.delete_env(@app, :post_media_folders) end)
      file = file!()
      view = open_editor(conn, slug, post)

      render_click(view, "open_media_selector", %{"field" => "featured_image_uuid"})
      choose(view, [file.uuid])

      eventually(fn ->
        folder = MediaFolders.post_folder(post[:uuid])
        assert %{parent_uuid: parent} = folder
        assert parent == group_folder_uuid(slug)
        assert reload(file).folder_uuid == folder.uuid
      end)
    end

    test "an OG image lands there", %{conn: conn, slug: slug, post: post} do
      file = file!()
      view = open_editor(conn, slug, post)

      render_click(view, "open_media_selector", %{"field" => "og_image_uuid"})
      choose(view, [file.uuid])

      assert_filed(file, slug)
    end

    test "an audio version lands there", %{conn: conn, slug: slug, post: post} do
      audio = audio_file!()
      view = open_editor(conn, slug, post)

      render_click(view, "open_media_selector", %{"field" => "audio_uuid"})
      choose(view, [audio.uuid])

      assert_filed(audio, slug)
    end

    test "an inserted Image component's file lands there", %{conn: conn, slug: slug, post: post} do
      file = file!()
      view = open_editor(conn, slug, post)

      send(view.pid, {:leaf_insert_request, %{type: :image}})
      choose(view, [file.uuid])

      assert_filed(file, slug)
    end

    test "an inserted Audio component's file lands there", %{conn: conn, slug: slug, post: post} do
      audio = audio_file!()
      view = open_editor(conn, slug, post)

      send(view.pid, {:leaf_toolbar_action, %{id: "phk-audio", selection: %{}}})
      choose(view, [audio.uuid])

      assert_filed(audio, slug)
    end

    test "every image of an inserted gallery lands there", %{conn: conn, slug: slug, post: post} do
      [first, second] = [file!(), file!()]
      view = open_editor(conn, slug, post)

      send(view.pid, {:leaf_toolbar_action, %{id: "phk-gallery", selection: %{}}})
      choose(view, [first.uuid, second.uuid])

      assert_filed(first, slug)
      assert_filed(second, slug)
    end

    test "a refused choice files nothing", %{conn: conn, slug: slug, post: post} do
      image = file!()
      view = open_editor(conn, slug, post)

      # An image offered to the audio slot is refused (`:wrong_type`).
      render_click(view, "open_media_selector", %{"field" => "audio_uuid"})
      choose(view, [image.uuid])

      control = file!()
      render_click(view, "open_media_selector", %{"field" => "featured_image_uuid"})
      choose(view, [control.uuid])
      assert_filed(control, slug)

      assert reload(image).folder_uuid == nil
    end

    test "a read-only session files nothing", %{conn: conn, slug: slug, post: post} do
      owner = open_editor(conn, slug, post)
      _ = render(owner)
      watcher = open_editor(build_conn(), slug, post)
      _ = render(watcher)

      assert :sys.get_state(watcher.pid).socket.assigns[:readonly?] == true

      picked = file!()
      choose(watcher, [picked.uuid])

      control = file!()
      render_click(owner, "open_media_selector", %{"field" => "featured_image_uuid"})
      choose(owner, [control.uuid])
      assert_filed(control, slug)

      assert reload(picked).folder_uuid == nil
    end
  end

  test "without the host hook nothing is filed", %{conn: conn, slug: slug, post: post} do
    file = file!()
    view = open_editor(conn, slug, post)

    render_click(view, "open_media_selector", %{"field" => "featured_image_uuid"})
    choose(view, [file.uuid])

    # No task is started on such a host, so there is nothing to wait for.
    assert reload(file).folder_uuid == nil
    assert group_folder_uuid(slug) == nil
  end
end
