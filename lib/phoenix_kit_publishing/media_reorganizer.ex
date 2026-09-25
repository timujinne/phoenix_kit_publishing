defmodule PhoenixKit.Modules.Publishing.MediaReorganizer do
  @moduledoc """
  Publishing's plan source for core's media reorganizer
  (`mix phoenix_kit.media.reorganize`), registered through
  `PhoenixKit.Modules.Publishing.media_reorganizer/0`.

  The group folders of `PhoenixKit.Modules.Publishing.MediaFolders` are
  planned by core's `PhoenixKit.Modules.Storage.Reorganizer.ResourceSource`,
  which applies the whole `Reorganizer.Source` contract: when the host's
  hooks change, a group's folder moves under the new parent (a folder
  found by its deterministic `publishing-group-<uuid>` name is renamed
  after the name hook and its group's pointer back-filled); a trashed or
  deleted group's folder is reported as an orphan; with no hook
  configured, nothing but reports.

  What is publishing's own: a group is live until trashed, its pointer is
  `data["media_folder_uuid"]`, and one extra report — `:unfiled`, a group
  whose posts use files still outside its folder, for which
  `PhoenixKit.Modules.Publishing.MediaAdoption` (`mix
  phoenix_kit_publishing.media.adopt --apply`) is the fix. The reorganizer
  moves folders only; it never files a file.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Publishing.MediaAdoption
  alias PhoenixKit.Modules.Publishing.MediaFolders
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Storage.Reorganizer.ResourceSource

  @source "publishing"

  @doc "The plan (`Reorganizer.Source.plan/2`); `opts` takes `:pending_days`."
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, opts \\ []), do: ResourceSource.plan(spec(), actor_uuid, opts)

  defp spec do
    %{
      source: @source,
      app: MediaFolders.app(),
      noun: "group",
      kinds: [
        %{
          kind: :group,
          schema: PublishingGroup,
          prefix: MediaFolders.folder_prefix(),
          pointer: MediaFolders.pointer(),
          live: &where(&1, [g], g.status != "trashed")
        }
      ],
      extra: &unfiled/2
    }
  end

  # A dry adoption plan: reads only, calls no hook.
  defp unfiled(actor_uuid, _opts) do
    case MediaAdoption.run(actor_uuid) do
      {:ok, %{groups: groups}} -> Enum.flat_map(groups, &unfiled_action/1)
      {:error, :not_configured} -> []
    end
  end

  defp unfiled_action(%{adopt: [], link: []}), do: []

  defp unfiled_action(entry) do
    count = length(entry.adopt) + length(entry.link)

    [
      %{
        source: @source,
        kind: :unfiled,
        label: "group #{entry.name} (#{entry.slug})",
        op: :report,
        reason:
          "#{count} file(s) its posts use are outside its media folder " <>
            "(#{length(entry.adopt)} to adopt, #{length(entry.link)} to link) — run " <>
            "`mix phoenix_kit_publishing.media.adopt --apply` " <>
            "(or PhoenixKit.Modules.Publishing.MediaAdoption.run(actor_uuid, apply?: true))"
      }
    ]
  end
end
