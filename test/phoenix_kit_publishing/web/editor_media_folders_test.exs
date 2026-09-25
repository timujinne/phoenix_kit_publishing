defmodule PhoenixKit.Modules.Publishing.Web.EditorMediaFoldersTest do
  @moduledoc """
  A file chosen in the editor's media picker lands in the post's group
  folder — on a host that opted into group media folders — and stays
  exactly where it was on one that did not.
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

  defp open_editor(conn, slug, post) do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope(user_uuid: user!().uuid))
      |> live("/admin/publishing/#{slug}/#{post[:uuid]}/edit")

    view
  end

  defp group_folder_uuid(slug), do: DBStorage.get_group_by_slug(slug).data["media_folder_uuid"]

  test "a featured image lands in the group's folder", %{conn: conn, slug: slug, post: post} do
    Application.put_env(@app, :attachments_parent_folder, {MediaFolders, :module_folder})
    Application.put_env(@app, :attachments_folder_name, {MediaFolders, :group_folder_name})
    file = file!()
    view = open_editor(conn, slug, post)

    render_click(view, "open_media_selector", %{"field" => "featured_image_uuid"})
    send(view.pid, {:media_selected, [file.uuid]})
    render(view)

    folder_uuid = group_folder_uuid(slug)
    assert is_binary(folder_uuid)
    assert reload(file).folder_uuid == folder_uuid
  end

  test "every image of an inserted gallery lands there", %{conn: conn, slug: slug, post: post} do
    Application.put_env(@app, :attachments_parent_folder, {MediaFolders, :module_folder})
    [first, second] = [file!(), file!()]
    view = open_editor(conn, slug, post)

    send(view.pid, {:leaf_toolbar_action, %{id: "phk-gallery", selection: %{}}})
    send(view.pid, {:media_selected, [first.uuid, second.uuid]})
    render(view)

    folder_uuid = group_folder_uuid(slug)
    assert is_binary(folder_uuid)
    assert reload(first).folder_uuid == folder_uuid
    assert reload(second).folder_uuid == folder_uuid
  end

  test "without the host hook nothing is filed", %{conn: conn, slug: slug, post: post} do
    file = file!()
    view = open_editor(conn, slug, post)

    render_click(view, "open_media_selector", %{"field" => "featured_image_uuid"})
    send(view.pid, {:media_selected, [file.uuid]})
    render(view)

    assert reload(file).folder_uuid == nil
    assert group_folder_uuid(slug) == nil
  end
end
