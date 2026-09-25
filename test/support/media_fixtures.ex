defmodule PhoenixKitPublishing.Test.MediaFixtures do
  @moduledoc """
  Rows for the media-folder tests: groups, posts with media references,
  storage files and folders — written straight through the repo so each
  test states exactly what the database holds.
  """

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKitPublishing.Test.Repo

  def group!(name, attrs \\ %{}) do
    {:ok, group} =
      %{name: name, slug: "g-#{System.unique_integer([:positive])}", mode: "slug"}
      |> Map.merge(attrs)
      |> DBStorage.create_group()

    group
  end

  @doc """
  A post of `group` with one version (`version_data`) and one content row
  per `{language, body, content_data}` in `contents`.
  """
  def post!(group, opts \\ []) do
    {:ok, post} =
      DBStorage.create_post(%{
        group_uuid: group.uuid,
        mode: "slug",
        slug: "p-#{System.unique_integer([:positive])}",
        trashed_at: Keyword.get(opts, :trashed_at)
      })

    {:ok, version} =
      DBStorage.create_version(%{
        post_uuid: post.uuid,
        version_number: 1,
        status: "draft",
        data: Keyword.get(opts, :version_data, %{})
      })

    for {language, body, data} <- Keyword.get(opts, :contents, [{"en", "", %{}}]) do
      {:ok, _} =
        DBStorage.create_content(%{
          version_uuid: version.uuid,
          language: language,
          status: "draft",
          title: "Title",
          content: body,
          data: data
        })
    end

    post
  end

  def file!(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    Repo.insert!(
      struct(
        StorageFile,
        Map.merge(
          %{
            original_file_name: "photo-#{n}.png",
            file_name: "photo-#{n}.png",
            mime_type: "image/png",
            file_type: "image",
            ext: "png",
            file_checksum: "checksum-#{n}",
            user_file_checksum: "user-checksum-#{n}",
            size: 1,
            status: "active"
          },
          attrs
        )
      )
    )
  end

  @doc "A real user row — a folder's creator must be one."
  def user! do
    Repo.insert!(%PhoenixKit.Users.Auth.User{
      email: "media-#{System.unique_integer([:positive])}@example.com",
      hashed_password: "x"
    })
  end

  def folder!(name, parent_uuid \\ nil, attrs \\ %{}) do
    Repo.insert!(struct(Folder, Map.merge(%{name: name, parent_uuid: parent_uuid}, attrs)))
  end

  @doc "A person's own storage library (core V203), besides the site's Media."
  def library! do
    n = System.unique_integer([:positive])

    Repo.insert!(%PhoenixKit.Modules.Storage.Library{
      name: "Private #{n}",
      kind: "user",
      visibility: "private",
      owner_uuid: user!().uuid,
      key_prefix: "private-#{n}",
      slug: "private-#{n}"
    })
  end

  def file_instance!(%StorageFile{uuid: file_uuid}, variant \\ "large") do
    Repo.insert!(%PhoenixKit.Modules.Storage.FileInstance{
      file_uuid: file_uuid,
      variant_name: variant,
      file_name: "#{file_uuid}-#{variant}.png",
      mime_type: "image/png",
      ext: "png",
      checksum: "instance-checksum-#{System.unique_integer([:positive])}",
      size: 1
    })
  end

  def reload(%StorageFile{uuid: uuid}), do: Repo.get!(StorageFile, uuid)
  def reload(%Folder{uuid: uuid}), do: Repo.get!(Folder, uuid)
  def reload(%PhoenixKit.Modules.Publishing.PublishingGroup{} = group), do: Repo.reload!(group)

  def linked?(%StorageFile{uuid: file_uuid}, folder_uuid) do
    import Ecto.Query

    Repo.exists?(
      from(l in PhoenixKit.Modules.Storage.FolderLink,
        where: l.file_uuid == ^file_uuid and l.folder_uuid == ^folder_uuid
      )
    )
  end
end

defmodule PhoenixKitPublishing.Test.MediaHooks do
  @moduledoc "Host hooks for the media-folder tests: a root answer, a broken one, fixed names."

  def root(_kind, _actor_uuid, _group), do: nil
  def boom(_kind, _actor_uuid, _group), do: raise("hook bug")
  def news(_group, _actor_uuid), do: {:ok, "News"}
  def too_long(_group, _actor_uuid), do: {:ok, String.duplicate("N", 300)}
end
