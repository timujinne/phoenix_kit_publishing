defmodule PhoenixKit.Modules.Publishing.StaleFixerGroupPointerTest do
  @moduledoc """
  `fix_stale_group/1` repairs `data` keys on a struct that can be older than
  the row. It used to write that struct's whole `data` back, wiping every key
  written since — the group's media folder pointer among them.
  """

  use PhoenixKitPublishing.DataCase, async: false

  import PhoenixKitPublishing.Test.MediaFixtures

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.StaleFixer
  alias PhoenixKit.Modules.Storage.ResourceFolders

  test "a data fix from a stale struct keeps keys written since, the folder pointer included" do
    stale = group!("News", %{data: %{"type" => "no-such-type"}})
    folder = folder!("News")

    :ok =
      ResourceFolders.write_pointer(
        stale.__struct__,
        stale.uuid,
        {:data, "media_folder_uuid"},
        folder.uuid
      )

    fixed = StaleFixer.fix_stale_group(stale)

    assert fixed.data["type"] == "custom"
    assert reload(stale).data["type"] == "custom"
    assert reload(stale).data["media_folder_uuid"] == folder.uuid
  end

  test "a fix the row no longer needs is not written from the stale struct" do
    stale = group!("News", %{data: %{"type" => "no-such-type"}})

    {:ok, _} =
      DBStorage.update_group(stale, %{
        data: Map.put(stale.data, "type", "blog")
      })

    StaleFixer.fix_stale_group(stale)

    assert reload(stale).data["type"] == "blog"
  end

  test "a group that needs no fix is not written" do
    group =
      group!("News", %{
        data: %{"type" => "custom", "item_singular" => "post", "item_plural" => "posts"}
      })

    assert StaleFixer.fix_stale_group(group) == group
  end
end
