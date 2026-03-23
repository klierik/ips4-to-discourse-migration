# IPS4 to Discourse Migration Toolkit

Ruby scripts for migrating Invision Community (IPS4) data to Discourse. Handles users, categories, topics, posts, attachments, avatars, SEO permalinks, and emoticons.

## Disclaimer

- Tested against **Invision Community v4.6.6**
- The source database had a full migration history: **IPB2 → IPB3 → IPB4** — legacy data artifacts from earlier versions may be present and are handled where encountered

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Post-run Tasks](#post-run-tasks)
- [Scripts Reference](#scripts-reference)
- [Configuration](#configuration)
- [Running Scripts](#running-scripts)
- [Field Coverage by Script](#field-coverage-by-script)
- [Key Implementation Details](#key-implementation-details)
  - [Nginx URL normalisation for legacy IPS4 links](#nginx-url-normalisation-for-legacy-ips4-links)
- [Log Files](#log-files)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

A running Discourse Docker instance with the following installed inside the container (one-time setup):

```bash
apt-get update && apt-get install -y default-libmysqlclient-dev
gem install mysql2 reverse_markdown
```

---

## Quick Start

Run `ipboard4_import_full.rb` as the starting point, then use the focused scripts to fix or update individual areas as needed:

1. **Validate first** — run `ipboard4_dry_run.rb` to surface data integrity issues before the full import
2. **Full import** — run `ipboard4_import_full.rb` to migrate users, categories, topics, posts, tags, PMs, and attachments
3. **Fix post content** — run `ipboard4_import_posts_only.rb` if you update `clean_up` logic and need to re-parse posts without a full re-import
4. **Update profiles** — run `ipboard4_import_profiles.rb` to apply username transliteration, bio, location, and other profile fields
5. **Re-import avatars** — run `ipboard4_import_avatars.rb` to import or refresh user avatars independently
6. **Fix permalinks** — run `ipboard4_fix_permalinks.rb` to create missing SEO permalink records and fix legacy URL redirects

Steps 3–6 are safe to re-run — they only update records that differ from current Discourse values.

---

## Post-run Tasks

After running either `ipboard4_import_full.rb` or `ipboard4_import_posts_only.rb`, run these rake tasks inside the container to keep Discourse fully synced:

```bash
RAILS_ENV=production bundle exec rake posts:rebake
RAILS_ENV=production bundle exec rake topics:fix_counts
```

### Why these are needed

**`posts:rebake`**

Both scripts write post content bypassing parts of the normal save pipeline. `posts:rebake` ensures the following derived data is rebuilt from the current `raw` content:

| Derived data                                | Why it matters                                                          |
| ------------------------------------------- | ----------------------------------------------------------------------- |
| Full-text search index (`post_search_data`) | Search will return stale or missing results until rebuilt               |
| `topic_links` table                         | "Links" counts on topics and backlink tracking will be wrong            |
| `quoted_posts` / `post_replies`             | Quote relationships used by the notification system                     |
| `cooked` HTML bake version                  | Ensures all posts are rendered with the current Discourse bake pipeline |

> **`import_posts_only`** uses `update_columns` which skips all callbacks — `posts:rebake` is required to fix search and links.
>
> **`import_full`** uses `PostCreator` which does fire callbacks during import, so search is indexed as posts are created. Running `posts:rebake` afterwards is still recommended to confirm everything is on the current bake version.

**`topics:fix_counts`**

Recalculates `posts_count`, `reply_count`, and category post/topic counts.

- **After `import_full`**: run this — counts can drift when posts are created in bulk outside normal user flows.
- **After `import_posts_only`**: not strictly needed (no posts are created or deleted), but safe to run as a sanity check.

---

## Scripts Reference

| Script                               | Purpose                                                                                                                                                   |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ipboard4_config.yml`                | Centralized config: DB credentials, table prefix, batch size, edge-case handling                                                                          |
| `ipboard4_dry_run.rb`                | Validates source DB and identifies data integrity issues before migration                                                                                 |
| `ipboard4_import_full.rb`            | Full migration: users, categories, topics, posts, tags, PMs, attachments                                                                                  |
| `ipboard4_import_posts_only.rb`      | Re-parses and updates existing Discourse posts from IPS4 source (fix content without full re-import)                                                      |
| `ipboard4_import_profiles.rb`        | Updates existing user profiles: transliterates Cyrillic usernames, sets bio, title, location, website, timezone. Safe to re-run                           |
| `ipboard4_import_avatars.rb`         | Imports/re-imports user avatars — local files and remote URLs. Safe to re-run                                                                             |
| `ipboard4_fix_permalinks.rb`         | Creates all missing SEO permalink records; fixes legacy `index.php?showtopic=` / `showforum=` 404s                                                        |
| `ipboard4_recalculate_user_stats.rb` | Recalculates `post_count` and `topic_count` in `user_stats` from actual post/topic data. Run after deletions to fix stale cached counters. Safe to re-run |
| `ipboard4_remove_scam_profiles.rb`   | Removes SCAM Gmail accounts: targets 0-post / 0-activity users with 2+ dots in Gmail local part or duplicate normalized addresses                         |

---

## Configuration

Edit `ipboard4_config.yml` before first run. All sections are described below.

### `database`

| Key            | Description                                                                                                       |
| -------------- | ----------------------------------------------------------------------------------------------------------------- |
| `host`         | Use `172.17.0.1` (Docker bridge IP) when the IPS4 database is on the host machine                                 |
| `port`         | MySQL port (default: `3306`)                                                                                      |
| `username`     | MySQL user                                                                                                        |
| `password`     | MySQL password                                                                                                    |
| `name`         | IPS4 database name                                                                                                |
| `table_prefix` | Must match your IPS4 installation (e.g. `ibf2_`). A wrong prefix makes every query return empty results silently. |

### `import`

| Key                      | Default                                        | Description                                                                                                                                                                                                                                                                                        |
| ------------------------ | ---------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `batch_size`             | `5000`                                         | Number of records processed per batch                                                                                                                                                                                                                                                              |
| `uploads_dir`            | `/mnt/ips4_uploads`                            | Path to the IPS4 uploads directory inside the container                                                                                                                                                                                                                                            |
| `run_users`              | `true`                                         | Import users                                                                                                                                                                                                                                                                                       |
| `run_categories`         | `true`                                         | Import forum categories                                                                                                                                                                                                                                                                            |
| `run_topics`             | `true`                                         | Import topic first posts                                                                                                                                                                                                                                                                           |
| `run_posts`              | `true`                                         | Import replies                                                                                                                                                                                                                                                                                     |
| `run_likes`              | `true`                                         | Import post likes                                                                                                                                                                                                                                                                                  |
| `run_tags`               | `true`                                         | Import topic tags                                                                                                                                                                                                                                                                                  |
| `run_articles`           | `true`                                         | Import IPS4 Pages articles                                                                                                                                                                                                                                                                         |
| `run_private_messages`   | `true`                                         | Import private messages                                                                                                                                                                                                                                                                            |
| `run_seo_permalinks`     | `true`                                         | Create SEO permalink records during full import                                                                                                                                                                                                                                                    |
| `wipe_revisions`         | `false`                                        | When `true`: deletes all `PostRevision` records for each updated post and resets `version`/`public_version` to `1`. Prevents import runs from polluting post edit history.                                                                                                                         |
| `max_attachment_size_kb` | `262144`                                       | Max upload size during import (default: 256 MB)                                                                                                                                                                                                                                                    |
| `allowed_iframe_domains` | `[https://jsfiddle.net/, https://codepen.io/]` | URL prefixes whose `<iframe>` tags are kept as live embeds. Added to `SiteSetting.allowed_iframes` at startup so iframes survive Discourse's HTML sanitizer. Values must start with `https://` and end with `/` (Discourse validation requirement). Add any other embed providers your forum used. |
| `allowed_extensions`     | _(list)_                                       | File extensions allowed as attachments during import — merged with Discourse's existing list                                                                                                                                                                                                       |

### `advanced_options`

| Key                           | Options                                          | Description                                                                                                                                                                                                                                              |
| ----------------------------- | ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `duplicate_email_handling`    | `dummy_email` _(recommended)_, `skip`            | **`dummy_email`**: imports the user with a generated fallback address (e.g. `imported_duplicate_12345@gmail.com`). **`skip`**: skips the user entirely — their posts become orphaned. Note: Discourse normalises Gmail dot-variants as the same address. |
| `invalid_email_handling`      | `dummy_email` _(recommended)_, `skip`            | Handles disposable providers (e.g. `mailinator.com`) and malformed addresses. **`dummy_email`**: uses `imported_fallback_12345@example.invalid`.                                                                                                         |
| `duplicate_username_handling` | `append_id` _(recommended)_, `skip`              | When two IPS4 users share a username: **`append_id`** → `Username_12345`.                                                                                                                                                                                |
| `invalid_username_handling`   | `sanitize_and_append_id` _(recommended)_, `skip` | Strips special chars and appends the IPS4 ID. `"Cool!@#User"` → `CoolUser_12345`. If nothing remains after stripping → `user_12345`.                                                                                                                     |
| `orphaned_topic_handling`     | `assign_system` _(recommended)_, `skip`          | Author missing or skipped: **`assign_system`** preserves the topic under the Discourse `system` account.                                                                                                                                                 |
| `orphaned_post_handling`      | `assign_system` _(recommended)_, `skip`          | Same as above but for individual replies. **`skip`** leaves a gap in the thread.                                                                                                                                                                         |

### `permalink_options`

| Key                            | Default | Description                                                                                                                                                                                                                                                                                            |
| ------------------------------ | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `create_post_anchor_redirects` | `true`  | Creates one permalink record per imported post for `index.php?showtopic=TID&p=PID` URLs. The redirect lands on the topic page (post anchor is dropped — Discourse's Permalink model does not support per-post targets). Can be slow on large forums (one insert per post) but is a one-time operation. |
| `force_update_post_anchors`    | `false` | When `true`: overwrites existing post-anchor permalink records with post-level URLs (`/t/slug/TID/POST_NUMBER`). Set back to `false` after the upgrade run to avoid unnecessary updates on future runs.                                                                                                |

### `website`

Controls resolution of IPS4 internal topic links (`showtopic=N`, `/topic/N-slug/`) to Discourse URLs during post content conversion. Set the whole `website` key to `false` to disable.

| Key          | Description                                                                                       |
| ------------ | ------------------------------------------------------------------------------------------------- |
| `old_domain` | Old IPS4 site domain — used to detect absolute internal links (e.g. `forum.com`)                  |
| `new_domain` | New Discourse domain — used to replace link text that contained the old domain (e.g. `forum.org`) |

### `debug`

| Key              | Description                                                                                                                                                                                                                     |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `single_post_id` | Set to a Discourse post ID to process only that post and exit. Prints IPS4 source HTML, old raw, and new raw — saves the change if content differs. Also settable via `DEBUG_POST_ID` env variable. Set to `0` to run normally. |

---

## Running Scripts

All scripts run **inside the container** as the `discourse` user. From the host:

```bash
# Dry run / pre-migration validation
docker exec -it forum-discourse su discourse -c \
  'RAILS_ENV=production bundle exec ruby /shared/ipboard4-migration/ipboard4_dry_run.rb'

# Full import
docker exec -it forum-discourse su discourse -c \
  'RAILS_ENV=production bundle exec ruby /shared/ipboard4-migration/ipboard4_import_full.rb'

# Re-parse posts only (after fixing content parsing logic, without full re-import)
docker exec -it forum-discourse su discourse -c \
  'RAILS_ENV=production bundle exec ruby /shared/ipboard4-migration/ipboard4_import_posts_only.rb'

# Import / re-import avatars
docker exec -it forum-discourse su discourse -c \
  'RAILS_ENV=production bundle exec ruby /shared/ipboard4-migration/ipboard4_import_avatars.rb'

# Update user profiles (username transliteration, bio, title, location, website, timezone)
docker exec -it forum-discourse su discourse -c \
  'RAILS_ENV=production bundle exec ruby /shared/ipboard4-migration/ipboard4_import_profiles.rb'

# Dry-run profile update (preview changes without writing)
DRY_RUN=1 docker exec -it forum-discourse su discourse -c \
  'RAILS_ENV=production bundle exec ruby /shared/ipboard4-migration/ipboard4_import_profiles.rb'

# Fix/create SEO permalinks
docker exec -it forum-discourse su discourse -c \
  'RAILS_ENV=production bundle exec ruby /shared/ipboard4-migration/ipboard4_fix_permalinks.rb'

# Recalculate user post/topic counts (fix stale counters after deletions)
docker exec -it forum-discourse su discourse -c \
  'RAILS_ENV=production bundle exec ruby /shared/ipboard4-migration/ipboard4_recalculate_user_stats.rb'

# Dry-run recalculate (show what would change without writing)
docker exec -it forum-discourse su discourse -c \
  'DRY_RUN=1 RAILS_ENV=production bundle exec ruby /shared/ipboard4-migration/ipboard4_recalculate_user_stats.rb'

# Remove SCAM Gmail accounts (dry-run first)
docker exec -it forum-discourse su discourse -c \
  'DRY_RUN=1 RAILS_ENV=production bundle exec ruby /shared/ipboard4-migration/ipboard4_remove_scam_profiles.rb'

docker exec -it forum-discourse su discourse -c \
  'RAILS_ENV=production bundle exec ruby /shared/ipboard4-migration/ipboard4_remove_scam_profiles.rb'
```

Or from a shell already inside the container (`./launcher enter forum-discourse`):

```bash
sudo -u discourse RAILS_ENV=production bundle exec ruby /shared/ipboard4-migration/ipboard4_import_posts_only.rb
```

---

## Field Coverage by Script

| User field                          | `import_full` | `import_profiles` | `import_avatars` |
| ----------------------------------- | :-----------: | :---------------: | :--------------: |
| username (basic ASCII sanitize)     |      ✅       |         —         |        —         |
| username (Cyrillic transliteration) |       —       |        ✅         |        —         |
| display name (`user.name`)          |      ✅       |        ✅         |        —         |
| email                               |      ✅       |         —         |        —         |
| title (`member_title`)              |      ✅       |        ✅         |        —         |
| bio (`pp_about_me` / `field_11`)    |      ✅       |        ✅         |        —         |
| date of birth                       |      ✅       |        ✅         |        —         |
| location (`member_location`)        |      ✅       |        ✅         |        —         |
| website (`pp_website`)              |      ✅       |        ✅         |        —         |
| timezone                            |      ✅       |        ✅         |        —         |
| avatar                              |      ✅       |         —         |        ✅        |
| registration date / IP              |      ✅       |         —         |        —         |
| last seen                           |      ✅       |         —         |        —         |
| ban / suspension                    |      ✅       |         —         |        —         |
| admin / moderator flags             |      ✅       |         —         |        —         |

`import_profiles` and `import_avatars` are safe to re-run against an existing import — they only update fields that differ from current Discourse values.

---

## Key Implementation Details

### HTML → Markdown conversion (`clean_up`)

IPS4 stores post content as HTML. The `clean_up` method in both `ipboard4_import_full.rb` and `ipboard4_import_posts_only.rb` converts it to Discourse-compatible Markdown via Nokogiri + ReverseMarkdown with the following handling:

**Quotes (`blockquote.ipsQuote`, `blockquote.ipsBlockquote`)**

Converted to Discourse `[quote="username,post:N,topic:N"]...[/quote]` BBCode. Placeholders are used to protect the BBCode from ReverseMarkdown processing. Placeholders must use **only alphanumeric characters** — ReverseMarkdown escapes underscores in plain text, which would break the placeholder substitution.

**Internal IPS4 links (`<___base_url___>/...`)**

IPS4 stores internal links with a `<___base_url___>` prefix. The script strips this prefix to produce root-relative URLs (e.g. `/index.php?showforum=24`), which work correctly on any environment (dev and production share the same DB). Using `Discourse.base_url` instead would hardcode the dev hostname into the database.

Non-`<___base_url___>` hrefs that start with `<` (other unresolvable IPS4 template variables) are removed entirely.

**Attachments**

Three URL patterns are resolved to Discourse uploads:

- `<___base_url___>/index.php?app=core&module=attach&attach_id=N`
- `attachment.php?id=N` (legacy)
- `<fileStore.core_Attachment>/path/to/file`

Files are renamed from the hashed storage filename to their original filename before upload. Missing files are replaced with `[Missing Attachment: filename]` placeholders.

**Emoticons**

`<fileStore.core_Emoticons>` image tags are mapped to Unicode emoji (e.g. `biggrin` → 😁, `wink` → 😉).

**Embeds / iframes**

| iframe source                                                        | Output                                                                                     |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| YouTube (`/embed/ID`)                                                | `https://www.youtube.com/watch?v=ID` — bare URL, Discourse onebox                          |
| YouTube nocookie (`/embed/ID`)                                       | `https://www.youtube.com/watch?v=ID` — bare URL, Discourse onebox                          |
| JSFiddle (`//jsfiddle.net/...`)                                      | `<iframe src="https://jsfiddle.net/...">` — live embed (domain added to `allowed_iframes`) |
| CodePen (`//codepen.io/...`)                                         | `<iframe src="https://codepen.io/...">` — live embed (domain added to `allowed_iframes`)   |
| IPS4 internal embed (`?do=embed`)                                    | Mapped to the corresponding Discourse topic URL                                            |
| IPS4 wrapped external URL (`<___base_url___>/index.php?...&url=...`) | Decoded and emitted as a bare URL                                                          |
| Generic protocol-relative (`//domain.com/...`)                       | `https://domain.com/...` — bare URL, Discourse attempts onebox                             |
| Absolute `http://` / `https://`                                      | Passed through as-is                                                                       |
| Unresolvable (relative, template variable, etc.)                     | Removed                                                                                    |

JSFiddle and CodePen iframes are kept as real `<iframe>` tags (using a placeholder to protect them from ReverseMarkdown). Both scripts extend `SiteSetting.allowed_iframes` at startup to include `jsfiddle.net` and `codepen.io` so the tags survive Discourse's HTML sanitizer. The original `src`, `width`, and `height` attributes from the IPS4 HTML are preserved; protocol-relative `//` URLs are prefixed with `https:`. Additional domains can be added via `import.allowed_iframe_domains` in `ipboard4_config.yml`.

**Spoilers (`blockquote.ipsStyle_spoiler`)**

Converted to Discourse `[details="title"]...[/details]` BBCode. The title is taken from `.ipsSpoiler_header span` (falls back to `"Spoiler"`). Processed after the code block `<br>` fix so code inside a spoiler has correct line breaks before content extraction.

| Case                   | Output                                 |
| ---------------------- | -------------------------------------- |
| Spoiler with title     | `[details="Hidden Text"]...[/details]` |
| Spoiler without header | `[details="Spoiler"]...[/details]`     |

**User mentions**

Two IPS4 patterns are handled:

- `<strong>@<a href="/profile/ID-slug">Name</a></strong>` — `@` and link inside one `<strong>`
- `<strong>@</strong><strong><a href="/profile/ID-slug">Name</a></strong>` — two separate `<strong>` nodes

The IPS4 member ID is extracted from the profile URL slug (e.g. `/profile/7758-name/` → ID `7758`), then resolved to the Discourse username via the import ID map.

| Case                                        | Output                                                                    |
| ------------------------------------------- | ------------------------------------------------------------------------- |
| User found with real username               | `@username` — functional Discourse mention                                |
| User found with generated fallback username | `@user406` — functional mention (ugly but valid)                          |
| User not found in DB                        | `[@John Snow](http://example.com/profile/7758-...)` — linked display name |

### Revision wipe (`wipe_revisions`)

Each call to `update_post_raw` uses `update_columns`, which bypasses the normal `post.revise` callback chain. However, previous import runs or the initial full import may have left `PostRevision` records behind, causing the post edit history UI to show spurious "script" revisions.

When `import.wipe_revisions: true`, after each `update_columns` write the script:

1. Deletes all `PostRevision` rows for that post (`PostRevision.where(post_id: ...).delete_all`)
2. Resets the post's `version` and `public_version` counters back to `1`

Set to `true` to enable (e.g. to prevent import runs from polluting post history). Defaults to `false` — revision history is preserved unless explicitly enabled.

### Nginx URL normalisation for legacy IPS4 links

Discourse looks up permalink records using an **exact** match of the request path + query string. A real-world IPS4 URL almost always carries extra parameters (`&hl=`, `&st=`, `&view=`, etc.) that are not part of the stored permalink — causing a 404 even when the correct record exists.

The nginx reverse-proxy config (`nginx-config/discourse.conf`) handles this before the request reaches Discourse:

```nginx
map $query_string $ips4_clean_showtopic {
    ~^showtopic=(\d+)$  "";   # already clean — no redirect needed
    ~showtopic=(\d+)    $1;   # extra params present — capture ID only
    default             "";
}
map $query_string $ips4_clean_showforum {
    ~^showforum=(\d+)$  "";
    ~showforum=(\d+)    $1;
    default             "";
}

location = /index.php {
    if ($ips4_clean_showtopic) { return 301 /index.php?showtopic=$ips4_clean_showtopic; }
    if ($ips4_clean_showforum) { return 301 /index.php?showforum=$ips4_clean_showforum; }
    proxy_pass http://discourse;
    ...
}
```

**How it works:**

- The `map` captures the numeric ID only when extra parameters are present alongside `showtopic`/`showforum`. An already-clean URL (e.g. `showtopic=48987` with nothing else) maps to `""` — no redirect fires and the request goes straight to Discourse.
- When extra params are detected, nginx issues a `301` to the canonical two-parameter URL (e.g. `/index.php?showtopic=48987`). Discourse then matches the stored permalink and issues a second `301` to the actual topic.
- Requests with no `showtopic` or `showforum` at all fall through to the proxy unchanged.

After editing the nginx config, reload:

```bash
docker-compose exec nginx nginx -t && docker-compose exec nginx nginx -s reload
```

---

### Permalink fixer

`ipboard4_fix_permalinks.rb` runs in two phases:

**Phase 1** — Fixes any existing Permalink rows stored with a leading slash (which Discourse never matches). Discourse strips the leading `/` from the incoming request before looking up the `permalinks` table, so `/index.php?showtopic=47375` must be stored as `index.php?showtopic=47375`.

**Phase 2** — Creates missing records for every IPS4 URL pattern. Both trailing-slash and no-trailing-slash variants of pretty URLs are created because different IPS4 traffic manager configurations produce different forms and it is not possible to predict which one search engines indexed.

| IPS4 URL                              | Stored as (no leading slash)         | Target                                 |
| ------------------------------------- | ------------------------------------ | -------------------------------------- |
| `/index.php?showtopic=47375`          | `index.php?showtopic=47375`          | Discourse topic                        |
| `/index.php?showforum=24`             | `index.php?showforum=24`             | Discourse category                     |
| `/topic/47375-slug/`                  | `topic/47375-slug/`                  | Discourse topic                        |
| `/topic/47375-slug`                   | `topic/47375-slug`                   | Discourse topic                        |
| `/forum/24-slug/`                     | `forum/24-slug/`                     | Discourse category                     |
| `/forum/24-slug`                      | `forum/24-slug`                      | Discourse category                     |
| `/index.php?showtopic=47375&p=123456` | `index.php?showtopic=47375&p=123456` | Exact Discourse post (`/t/slug/TID/N`) |

**Post anchor redirects** (`index.php?showtopic=TID&p=PID`) are controlled by `permalink_options.create_post_anchor_redirects`. When enabled (default: `true`), the script creates one permalink per imported post using `external_url` pointing to the exact post: `/t/topic-slug/TID/POST_NUMBER`. First posts (`new_topic = 1`) are resolved via `t-TID`; replies are resolved via their own post ID — so `post_number` is always accurate. This phase can be slow for large forums (one DB insert per post) but is a one-time operation.

If a previous run created topic-level records instead of post-level ones, set `permalink_options.force_update_post_anchors: true` to overwrite them. Set it back to `false` after the upgrade run.

#### Output statuses

Each processed record prints one status line to stdout and the log file:

**Phase 1 — fix existing**

| Status                                            | Meaning                                                                   |
| ------------------------------------------------- | ------------------------------------------------------------------------- |
| `FIXED leading slash: /old → new`                 | Leading slash removed from existing record                                |
| `REMOVED duplicate (correct record exists): /old` | The broken `/old` record was destroyed — a correct record already existed |

**Phase 2 — create missing**

| Status                                    | Meaning                                                                                                                    |
| ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `CREATED: url → topic_id=N`               | New topic permalink created                                                                                                |
| `CREATED: url → category_id=N`            | New category permalink created                                                                                             |
| `CREATED anchor: url → /t/slug/TID/N`     | New post-anchor permalink created                                                                                          |
| `UPDATED anchor: url → /t/slug/TID/N`     | Existing post-anchor permalink overwritten (`force_update_post_anchors: true`)                                             |
| `SKIP (exists): url`                      | Permalink already exists — skipped                                                                                         |
| `COLLISION (RecordInvalid): url — …`      | Two different IPS4 slugs normalised to the same value by Discourse — harmless, existing record already covers the redirect |
| `COLLISION (RecordNotUnique): url`        | Race condition between existence check and insert — harmless, skipped                                                      |
| `COLLISION (anchor update/create …): url` | Post-anchor upsert failed — logged and counted, does not abort the run                                                     |

#### Summary output

At the end of the run the script prints a summary:

```
=== Summary ===
  Topics:
    Legacy (showtopic) created : 12450
    Pretty-URL created         : 24820
  Categories:
    Legacy (showforum) created : 38
    Pretty-URL created         : 76
  Post anchors (showtopic&p=)  : created 89203, updated 0
  Skipped (no Discourse mapping): 14
  Skipped (blank SEO slug)      : 3
  Skipped (URL collision)       : 47 — redirect covered by existing record
```

- **No Discourse mapping** — IPS4 topic or forum has no corresponding imported record (e.g. was excluded from the full import)
- **Blank SEO slug** — IPS4 `title_seo` / `name_seo` field is empty; pretty-URL variants are skipped to avoid creating broken records
- **URL collision** — a record for that exact URL already exists; the existing redirect is preserved

---

## Log Files

All scripts except `ipboard4_import_full.rb` and `ipboard4_dry_run.rb` write a log file on every run. Logs are written to:

```
shared/standalone/ipboard4-migration/logs/          ← host path
/shared/ipboard4-migration/logs/                    ← inside container
```

Each run creates a timestamped file so previous logs are never overwritten:

```
logs/import_posts_2026-03-20_15-40-22.log
logs/import_avatars_2026-03-20_15-33-04.log
logs/import_profiles_2026-03-20_15-32-11.log
logs/fix_permalinks_2026-03-20_15-45-10.log
logs/recalculate_user_stats_2026-03-20_15-50-00.log
logs/remove_scam_2026-03-20_15-55-00.log
```

### What gets logged

| Script                   | Logged entries                                                                                                                           |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `import_posts_only`      | Missing attachment files, upload failures, image processing errors, regex timeouts — all include the IPS4 → Discourse post context       |
| `import_avatars`         | Failed local uploads (with file path), failed remote downloads (with URL), HTTP errors                                                   |
| `import_profiles`        | User updates that raised an exception, with IPS4 ID, Discourse username, and full error class + message                                  |
| `fix_permalinks`         | Every FIXED, REMOVED, CREATED, UPDATED, SKIP, and COLLISION status line — full run trace with timestamps, plus the summary block         |
| `recalculate_user_stats` | In live mode: number of rows updated per counter. In dry-run mode: every user whose counters would change (`username`, old → new values) |
| `remove_scam_profiles`   | Every SKIP (has activity) and DELETE line with user ID, username, email, reason, and dot count; errors during deletion                   |

### Log format

**`import_profiles`**

```
# ipboard4_import_profiles — 2026-03-20 18:07:51
# Config: /shared/ipboard4-migration/ipboard4_config.yml

[2026-03-20 18:09:20] ips4=16535 user=ExampleUser | ActiveRecord::RecordInvalid: Validation failed: About Me is too long (maximum is 3000 characters)
[2026-03-20 18:10:01] ips4=46713 user=AnotherUser | ActiveRecord::RecordInvalid: Validation failed: About Me is too long (maximum is 3000 characters)

# --- Summary ---
# Elapsed   : 00:04:24
# Processed : 48881
# Updated   : 48844
# Unchanged : 8
# No user   : 0
# Failed    : 29
# Dry run   : false
```

**`import_posts_only`**

```
# ipboard4_import_posts_only — 2026-03-21 07:43:36
# Config: /shared/ipboard4-migration/ipboard4_config.yml

[2026-03-21 07:58:06] Upload persisted? false for attach_id 441 file index.html: Sorry, but the file you provided is empty. | IPS4 post 372148 → Discourse post #331549 (/t/41391/3)
[2026-03-21 08:09:18] Upload persisted? false for attach_id 1869 file index.html: Sorry, but the file you provided is empty. | IPS4 topic t-59203 → Discourse post #44673 (/t/44673/1)

# --- Summary ---
# Elapsed             : 00:45:55
# Topics processed    : 46488
# Topics revised      : 319
# Posts processed     : 300767
# Posts revised       : 1969
# PMs processed       : 107328
# PMs revised         : 740
```

**`fix_permalinks`**

```
# ipboard4_fix_permalinks — 2026-03-21 08:05:02
# Config: /shared/ipboard4-migration/ipboard4_config.yml
# Table prefix: ibf2_

[2026-03-21 08:05:03]   SKIP (exists): index.php?showtopic=38
[2026-03-21 08:13:51]   SKIP (exists): forum/242-commercial/
[2026-03-21 08:13:51]   SKIP (exists): forum/242-commercial

# --- Summary ---
#
# === Summary ===
#   Topics:
#     Legacy (showtopic) created : 46488
#     Pretty-URL created         : 92976
#   Categories:
#     Legacy (showforum) created : 167
#     Pretty-URL created         : 334
#   Post anchors (showtopic&p=)  : created 0, updated 0
#   Skipped (no Discourse mapping): 3402
#   Skipped (blank SEO slug)      : 0
#   Skipped (URL collision)       : 139965 — redirect covered by existing record
#
# Done.
```

- Log file path is always printed at the end of the run
- For `import_profiles` and `import_avatars` the path is printed only when there are failures (or dry-run mode)
- The `logs/` directory is created automatically on first run

---

## Troubleshooting

- **Database connection refused**: Verify the bridge IP is `172.17.0.1` and the DB user has permissions for the `172.17.0.%` subnet.
- **Redis connection refused**: Scripts must run as `su discourse -c '...'` to load the correct socket path environment variables.
- **Missing `base.rb`**: Scripts require `/var/www/discourse/script/import_scripts/base.rb`. Verify the path exists inside the container.
- **Script reports "0 records added"**: Check `table_prefix` in `ipboard4_config.yml` — a wrong prefix makes every query return empty results silently.
