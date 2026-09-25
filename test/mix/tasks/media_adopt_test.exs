defmodule Mix.Tasks.PhoenixKitPublishing.Media.AdoptTest do
  use PhoenixKitPublishing.DataCase, async: false

  import PhoenixKitPublishing.Test.MediaFixtures

  alias Mix.Tasks.PhoenixKitPublishing.Media.Adopt
  alias PhoenixKit.Modules.Publishing.MediaFolders

  @app :phoenix_kit_publishing

  setup do
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
      Application.delete_env(@app, :attachments_parent_folder)
      Application.delete_env(@app, :attachments_folder_name)
    end)
  end

  defp configure_default_hooks do
    Application.put_env(@app, :attachments_parent_folder, {MediaFolders, :module_folder})
    Application.put_env(@app, :attachments_folder_name, {MediaFolders, :folder_name})
  end

  defp output do
    receive do
      {:mix_shell, _kind, [text]} -> text <> output()
    after
      0 -> ""
    end
  end

  test "an unknown option stops before anything runs" do
    assert catch_exit(Adopt.run(["--aply"])) == {:shutdown, 1}
    assert output() =~ "--aply"
  end

  test "explains how to opt in on a host without the hook" do
    assert catch_exit(Adopt.run([])) == {:shutdown, 1}
    assert output() =~ "attachments_parent_folder"
  end

  test "names a hook that cannot be called and plans nothing" do
    Application.put_env(@app, :attachments_parent_folder, {MediaFolders, :no_such_hook})

    assert catch_exit(Adopt.run([])) == {:shutdown, 1}
    assert output() =~ "no_such_hook is not callable"
  end

  test "a dry run prints the plan and writes nothing" do
    configure_default_hooks()
    file = file!()
    post!(group!("News"), version_data: %{"featured_image_uuid" => file.uuid})

    Adopt.run([])

    assert output() =~ "dry run"
    assert reload(file).folder_uuid == nil
  end

  test "--apply files the media" do
    configure_default_hooks()
    file = file!()
    post!(group!("News"), version_data: %{"featured_image_uuid" => file.uuid})

    Adopt.run(["--apply"])

    assert output() =~ "adopted 1"
    assert reload(file).folder_uuid != nil
  end
end
