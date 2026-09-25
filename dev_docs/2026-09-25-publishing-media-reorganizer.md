# Publishing media in folders — design (2026-09-25)

Goal: a post's media lives in a folder of the module, one folder per
publishing group (`Publishing/News`, `Publishing/Legal`) and, when the host
wants it, one per post inside that (`Publishing/News/spring-fair`); existing
files are moved there once, new ones land there by themselves, and every
host can opt in or shape the tree through config.

## Hierarchy

```
<parent answered by the host hook>   default hook: "Publishing" at the root
└── <group folder>                   default hook: the group's name ("News")
    │                                fallback: "publishing-group-<uuid>"
    └── <post folder>                only with :post_media_folders
                                     default hook: the slug, or "2026-09-25 14:30"
                                     for a timestamp post
                                     fallback: "publishing-post-<uuid>"
```

A post folder's parent is always its group's folder; the parent hook is asked
for groups only.

## Configuration (opt-in)

Nothing changes on a host that configures nothing: no folders are created,
uploads stay where they are, the reorganizer only reports. The hooks are
core's per-record convention (`PhoenixKit.Modules.Storage.ResourceFolders`):

```elixir
config :phoenix_kit_publishing,
  attachments_parent_folder: {PhoenixKit.Modules.Publishing.MediaFolders, :module_folder},
  attachments_folder_name: {PhoenixKit.Modules.Publishing.MediaFolders, :folder_name}

# and, for a folder per post inside its group's:
config :phoenix_kit_publishing, :post_media_folders, true
```

The two functions ship with the module (the ready-made tree above). A host can
point either key at its own function instead: the parent hook is called as
`fun(:group, actor_uuid, group)` and answers `{:ok, folder_uuid}` or `nil`
(root); the name hook as `fun(subject, actor_uuid)` — a group, or with post
folders a post — → `{:ok, name}` or `nil`.

## Pointers (no migration)

So that renaming or moving a folder in the media browser, or renaming a group
or a post, never makes a second folder:

- group → `phoenix_kit_publishing_groups.data["media_folder_uuid"]` (written
  with `ResourceFolders.write_pointer/4`, one JSONB key, no changeset);
- post → `data["media_folder_uuid"]` on **every version** of the post. Posts
  have no JSONB column; versions do, a new version copies its source's
  `data`, and a post save rewrites a version's `data` only after locking the
  post row and re-reading the version — the same row lock a claim takes before
  it writes the key (one `update_all` with `jsonb_set` over the post's
  versions). A post's pointer is its newest version's that names a live Media
  folder. The alternative — a column on posts — is a shape change, V2 of the
  module's migration chain plus core's `ExpectedSchema` exclusion; not needed;
- module folder → setting `publishing_media_folder_uuid`.

## Which files belong where

Every post of an active group, every version, and in each: version `data`
`featured_image_uuid` / `audio_uuid`; content `data` `featured_image_uuid` /
`featured_image_id` / `og.image_uuid`; content body `file_uuid="…"` (the PHK
components) and `/file/<uuid>/…` baked URLs. Uuids that are not a row of
`phoenix_kit_files` are ignored. Trashed groups are skipped.

Without post folders all of a group's posts (trashed ones too — they can be
restored) file into the group folder. With them each live post files into
its own folder; a trashed post's files, where no live post of the group took
them, into the group folder (a trashed post gets no new folder — the
reorganizer would only report it as an orphan).

## Shared files (claims / duplicates)

Core's attach rule decides, so the result is the same as any other module's:
a file with no home is **adopted** (its `folder_uuid` becomes the folder); a
file already homed elsewhere — another group or post, another module, a
person's own folder — is **linked** (`FolderLink`), never moved. One
exception, with post folders: a file homed in its group's own folder (filed
there before post folders were on, or picked before the post was first
saved) is **moved down** into the post's folder — a compare-and-set on its
home, the target folder share-locked first, as core's attach takes it. A file
several groups or posts use is homed by the first (groups in `position`,
`inserted_at`, uuid order; posts in `inserted_at`, uuid order) and linked into
the others. A trashed file, a system-managed one (tile chunks, an edited
image's hidden original), or one in another storage library is reported and
left alone.

## A post that changes group

The module has no operation that moves a post to another group. If
`group_uuid` changes by other means, the post's folder is left under the old
group's folder by the editor (the pointer wins), and **adoption moves it**
under the new group's folder on `--apply` (`relocate` in the report) — only
when it sits directly under another publishing group's folder; a post folder a
person put anywhere else stays where it is.

## Three moving parts

1. **Existing files, once** — `MediaAdoption.run(actor_uuid, apply?: false)`
   (`mix phoenix_kit_publishing.media.adopt [--apply]`). Dry run by default,
   writes nothing and calls no hook, but refuses when a configured hook is not
   callable; `--apply` finds-or-creates each group's and post's folder (only
   those with files to file) with the hooks called strictly — a failing hook
   leaves that group or post unfiled, never filed at the media root — and
   files. Core's `Reorganizer` cannot do this step: it moves existing
   *folders* and by contract never creates folders nor touches files, and
   publishing had no folders at all. The step reuses core's
   `ResourceFolders.ensure/4` and `attach/2`; re-running it is a no-op.
2. **New files** — the editor files every file chosen in the media picker
   (featured / OG / audio slot, Image / Gallery / Audio component) into the
   post's folder (post folders on and the post saved) or the group's, right
   after the choice lands, in a task under `PhoenixKit.TaskSupervisor` (a
   gallery is one transaction per image). A trashed group, a trashed post (its
   files go to the group folder) and system-managed files are handled as in
   step 1. The picker itself stays unscoped: people still browse the whole
   library.
3. **Later changes of the tree** — `media_reorganizer/0` registers
   `MediaReorganizer` (core's `ResourceSource`, kind `:group`) with
   `mix phoenix_kit.media.reorganize`: when a host changes its hooks, the
   group folders move under the new parent (pointer back-fill for a folder
   found by its deterministic name); post folders are not planned — they
   travel with their group's. Orphans, reported only: core's scan reports a
   deterministic-named folder of a trashed or deleted group, but only at the
   root or under a parent a hook named for a live group; publishing adds every
   live Media folder a trashed group or a trashed post points at (any name,
   anywhere), once per folder, unless a live group or post points at it too
   or it is already reported; a folder in another library is never reported.
   A hard-deleted group's or post's pointer went with its row, so only core's
   scan (groups, deterministic names) can find its folder. Two more reports: a
   name hook that can't be called (core reports only the parent hook, and asks
   the name hook only once a folder exists), and `:unfiled`, groups and posts
   whose files are still outside their folder, so the core dry run tells the
   host when step 1 is needed. With the ready-made parent hook, a core dry run
   can create the `Publishing` folder: the hook is called for any group that
   has a folder, and creating it on first use is the hook's job.

## Libraries and concurrency

Core's by-name folder lookups (`ResourceFolders.find_under/2`, `resolve/1`,
the "name taken" check in `ensure/4`) do not look at the storage library
(V202/V203) and take the first row without an order, so a `Publishing` or
`News` folder at the root of a person's private library could be taken for
the module's, or push a group onto its fallback name. Publishing does its own
lookups in Media, oldest first — the module folder, a group's or post's
folder by host or deterministic name, every pointer — and asks `ensure/4`
only to create; new folders go to Media (the column default).

A claim (group or post) is one transaction:

1. the `{parent, host name}` and `{parent, deterministic name}` advisory locks
   (`ResourceFolders.lock_name/2`, the keys core's `ensure/4` and the
   reorganizer's pointer back-fill take), in sorted order, so two claims
   whose names cross never wait on each other in opposite orders;
2. the owner's row `FOR UPDATE` (the group, or the post — the lock a post save
   takes before rewriting a version's `data`), and its pointer re-read under
   it: a folder claimed since is used as is, never replaced;
3. the lookup, the name choice (a name another owner's folder holds falls
   back to the deterministic one), the create — under a savepoint, so a name
   core refuses (taken, too long) falls back to the deterministic one in the
   same transaction — and the pointer write; an owner deleted meanwhile makes
   the write answer `{:error, :not_found}` and rolls the new folder back.

So two same-named groups — group names are not unique — never share a folder.
The name locks and the rollback are pinned by tests (a second connection
holding each lock; a deleted owner); the sorted order and the row lock are
not (they need two real concurrent sessions, which the SQL sandbox does not
give).

## Baked URLs

`/file/<uuid>/<variant>/<token>`: the token is `md5("<uuid>:<variant>" <>
secret_key_base)` (`URLSigner.generate_token/2`) and the bucket object key is
stored on the file instance — neither depends on `folder_uuid` or a
`FolderLink`. Adopting, linking or moving a file down changes no URL and no
stored content.

## Core floor

`ResourceFolders` / `ResourceSource` ship in core 2.38.0 (identical in
2.39.0), so the `:phoenix_kit` floor moves from `~> 2.14` to `~> 2.38`.
