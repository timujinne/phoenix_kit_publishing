# Publishing media in folders — design (2026-09-25)

Goal: a post's media lives in a folder of the module, one folder per
publishing group (`Publishing/News`, `Publishing/Legal`), existing files are
moved there once, new ones land there by themselves, and every host can opt
in or shape the tree through config.

## Hierarchy

```
<parent answered by the host hook>        default hook: "Publishing" at the root
└── <group folder>                        default hook: the group's name ("News")
                                          fallback: "publishing-group-<uuid>"
```

One folder per **group**, not per post. Per-post folders do not fit the core
convention cleanly: `phoenix_kit_publishing_posts` has no JSONB column to keep
a folder pointer in (it would need a migration in this module's chain), a post
title is per language, and a third tier makes every picker listing deeper for
little gain. A later `:post` kind (parent hook answers the group folder) can be
added on top of this without changing anything below.

## Configuration (opt-in)

Nothing changes on a host that configures nothing: no folders are created,
uploads stay where they are, the reorganizer only reports. The hooks are
core's per-record convention (`PhoenixKit.Modules.Storage.ResourceFolders`):

```elixir
config :phoenix_kit_publishing,
  attachments_parent_folder: {PhoenixKit.Modules.Publishing.MediaFolders, :module_folder},
  attachments_folder_name: {PhoenixKit.Modules.Publishing.MediaFolders, :group_folder_name}
```

The two functions ship with the module (the ready-made tree above). A host can
point either key at its own function instead: the parent hook is called as
`fun(:group, actor_uuid, group)` and answers `{:ok, folder_uuid}` or `nil`
(root); the name hook as `fun(group, actor_uuid)` → `{:ok, name}` or `nil`.

Pointers, so renaming or moving a folder in the media browser is respected:

- group → `phoenix_kit_publishing_groups.data["media_folder_uuid"]` (written
  with `ResourceFolders.write_pointer/4`, one JSONB key, no changeset);
- module folder → setting `publishing_media_folder_uuid`.

## Which files belong to a group

Every post of the group (trashed posts included — they can be restored), every
version, and in each: version `data` `featured_image_uuid` / `audio_uuid`;
content `data` `featured_image_uuid` / `featured_image_id` / `og.image_uuid`;
content body `file_uuid="…"` (the PHK components) and `/file/<uuid>/…` baked
URLs. Uuids that are not a row of `phoenix_kit_files` are ignored. Trashed
groups are skipped.

## Shared files (claims / duplicates)

Core's attach rule decides, so the result is the same as any other module's:
a file with no home is **adopted** (its `folder_uuid` becomes the group
folder); a file already homed elsewhere — another group, another module, a
person's own folder — is **linked** (`FolderLink`), never moved. A file used by
two groups is homed by the first (groups in `position`, `inserted_at`, uuid
order) and linked into the others. A trashed file, or one in another storage
library, is reported and left alone.

## Three moving parts

1. **Existing files, once** — `MediaAdoption.run(actor_uuid, apply?: false)`
   (`mix phoenix_kit_publishing.media.adopt [--apply]`). Dry run by default,
   writes nothing and calls no hook, but refuses when a configured hook is not
   callable; `--apply` finds-or-creates each group's folder (only for groups
   that have files to file) with the hooks called strictly — a failing hook
   leaves that group unfiled, never filed at the media root — and attaches.
   Core's `Reorganizer` cannot do this step: it moves existing *folders* and by
   contract never creates folders nor touches files, and publishing had no
   folders at all. The step reuses core's `ResourceFolders.ensure/4` and
   `attach/2` rather than writing rows itself; re-running it is a no-op.
2. **New files** — the editor files every file chosen in the media picker
   (featured / OG / audio slot, Image / Gallery / Audio component) into the
   post's group folder right after the choice lands, in a task under
   `PhoenixKit.TaskSupervisor` (a gallery is one transaction per image). A
   trashed group and system-managed files are skipped, as in step 1. The
   picker itself stays unscoped: people still browse the whole library.
3. **Later changes of the tree** — `media_reorganizer/0` registers
   `MediaReorganizer` (core's `ResourceSource`, kind `:group`) with
   `mix phoenix_kit.media.reorganize`: when a host changes its hooks, the group
   folders move under the new parent (pointer back-fill for a folder found by
   its deterministic name). Orphans: core's scan reports a deterministic-named
   folder of a trashed or deleted group (at the root or under a parent a hook
   named); a host-named one (`News`) of a trashed group is reported by
   publishing's own `extra`, through the pointer. A hard-deleted group's
   host-named folder cannot be traced (its pointer went with the row). The
   other `extra` report (`:unfiled`) lists groups whose files are still outside
   their folder, so the core dry run tells the host when step 1 is needed.

## Libraries

Core's by-name folder lookups (`ResourceFolders.find_under/2`, `resolve/1`)
do not look at the storage library (V202/V203), so a `Publishing` or `News`
folder at the root of a person's private library could be taken for the
module's. Publishing looks the module folder up in Media only and never adopts
a group folder outside Media; new folders go to Media (the column default).

## Baked URLs

`/file/<uuid>/<variant>/<token>`: the token is `md5("<uuid>:<variant>" <>
secret_key_base)` (`URLSigner.generate_token/2`) and the bucket object key is
stored on the file instance — neither depends on `folder_uuid` or a
`FolderLink`. Adopting or linking a file changes no URL and no stored content.

## Core floor

`ResourceFolders` / `ResourceSource` ship in core 2.38.0 (identical in 2.39.0),
so the `:phoenix_kit` floor moves from `~> 2.14` to `~> 2.38`.
