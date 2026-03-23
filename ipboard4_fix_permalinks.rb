# frozen_string_literal: true

# =============================================================================
# ipboard4_fix_permalinks.rb
#
# PURPOSE:
#   Ensures every IPS4 URL pattern that should redirect to Discourse has a
#   matching Permalink record. Handles both the modern IPS4 "pretty" URL
#   format and the legacy query-string format that causes 404s.
#
# URL PATTERNS COVERED:
#   1. index.php?showtopic=XXXXX      -> Discourse topic  (LEGACY)
#   2. index.php?showforum=XX         -> Discourse category (LEGACY)
#   3. topic/XXXXX-slug/              -> Discourse topic  (IPS4 pretty, trailing slash)
#   4. topic/XXXXX-slug               -> Discourse topic  (IPS4 pretty, no trailing slash)
#   5. forum/XX-slug/                 -> Discourse category (IPS4 pretty, trailing slash)
#   6. forum/XX-slug                  -> Discourse category (IPS4 pretty, no trailing slash)
#
# HOW DISCOURSE PERMALINK MATCHING WORKS:
#   Discourse strips the leading "/" from the request path and appends
#   "?query_string" when present before looking up a Permalink record.
#   So the stored url for "index.php?showtopic=47375" must be exactly:
#     index.php?showtopic=47375
#   (no leading slash, with query string).
#
# RUN INSIDE DISCOURSE DOCKER:
#   sudo -u discourse RAILS_ENV=production bundle exec ruby \
#     /shared/ipboard4-migration/ipboard4_fix_permalinks.rb
# =============================================================================

require "mysql2"
require "yaml"
require "fileutils"
require File.expand_path('/var/www/discourse/script/import_scripts/base.rb')

class ImportScripts::IPBoard4PermalinkFixer < ImportScripts::Base

    # Try multiple config locations so the script works whether placed inside
    # script/import_scripts/ or in /shared/ipboard4-migration/.
    CONFIG_PATHS = [
        File.expand_path(File.dirname(__FILE__) + "/ipboard4_config.yml"),
        File.expand_path(File.dirname(__FILE__) + "/ipboard4-migration/ipboard4_config.yml"),
        File.expand_path("/shared/ipboard4_config.yml"),
        File.expand_path("/shared/ipboard4-migration/ipboard4_config.yml")
    ]
    CONFIG_PATH = CONFIG_PATHS.find { |p| File.exist?(p) } || (raise "Could not find ipboard4_config.yml in any of: #{CONFIG_PATHS.join(', ')}")
    CONFIG = YAML.load_file(CONFIG_PATH)

    TABLE_PREFIX = CONFIG.dig("database", "table_prefix") || "ibf2_"

    def initialize
        super

        @client = Mysql2::Client.new(
            host:     ENV["DB_HOST"] || CONFIG.dig("database", "host")     || "localhost",
            username: ENV["DB_USER"] || CONFIG.dig("database", "username") || "root",
            password: ENV.has_key?("DB_PW") ? ENV["DB_PW"] : CONFIG.dig("database", "password").to_s,
            database: ENV["DB_NAME"] || CONFIG.dig("database", "name")     || "ips4",
            port:     CONFIG.dig("database", "port")                       || 3306
        )

        @client.query("SET NAMES utf8mb4")
    end

    def execute
        log_dir   = "/shared/ipboard4-migration/logs"
        FileUtils.mkdir_p(log_dir)
        @log_path = File.join(log_dir, "fix_permalinks_#{Time.now.strftime("%Y-%m-%d_%H-%M-%S")}.log")
        @log_file = File.open(@log_path, "w")
        @log_file.sync = true
        @log_file.puts "# ipboard4_fix_permalinks — #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}"
        @log_file.puts "# Config: #{CONFIG_PATH}"
        @log_file.puts "# Table prefix: #{TABLE_PREFIX}"
        @log_file.puts ""

        puts "=== IPS4 Permalink Fixer ==="
        puts "Config: #{CONFIG_PATH}"
        puts "Table prefix: #{TABLE_PREFIX}"
        puts "Log: #{@log_path}"
        puts ""

        fix_existing_permalinks
        create_missing_permalinks
        print_summary

        @log_file&.close
        puts "Log written to: #{@log_path}"
    end

    # -------------------------------------------------------------------------
    # Phase 1: Fix any existing Permalink rows that were stored with a leading
    # slash. Discourse's before_validation callback normally prevents this, but
    # records created via raw SQL or older import scripts may have slipped
    # through. A leading slash causes the lookup to never match.
    # -------------------------------------------------------------------------
    def fix_existing_permalinks
        puts "--- Phase 1: Fixing existing Permalinks stored with a leading slash ---"

        fixed_count     = 0
        destroyed_count = 0

        Permalink.where('url LIKE ?', '/%').find_each do |permalink|
            new_url = permalink.url.sub(%r{\A/+}, "")  # strip ALL leading slashes

            if Permalink.exists?(url: new_url)
                # A correct record already exists; remove the broken duplicate.
                permalink.destroy
                destroyed_count += 1
                log_info "REMOVED duplicate (correct record exists): #{permalink.url}"
            else
                # Update using the model so validations run and the change is
                # properly recorded. Fall back to update_columns only on failure.
                unless permalink.update(url: new_url)
                    permalink.update_columns(url: new_url)
                end
                fixed_count += 1
                log_info "FIXED leading slash: #{permalink.url} → #{new_url}"
            end
        end

        puts "  Fixed: #{fixed_count}  |  Removed duplicates: #{destroyed_count}"
        puts ""
    end

    # -------------------------------------------------------------------------
    # Phase 2: Create all missing Permalink records by querying the IPS4
    # database. We handle both URL families:
    #
    #   A) Legacy query-string URLs (index.php?showtopic= / index.php?showforum=)
    #      These are the primary source of 404s. Discourse matches them by
    #      storing the full "path?query" string without a leading slash.
    #
    #   B) IPS4 pretty-URL slugs (topic/TID-slug/ and forum/ID-slug/)
    #      Both the trailing-slash and no-trailing-slash variants are stored
    #      because different IPS4 traffic manager configurations use different
    #      forms and we cannot predict which one Google indexed.
    # -------------------------------------------------------------------------
    def create_missing_permalinks
        puts "--- Phase 2: Creating missing Permalink records ---"

        @added_topics_legacy   = 0
        @added_topics_pretty   = 0
        @added_cats_legacy     = 0
        @added_cats_pretty     = 0
        @added_post_anchors    = 0
        @updated_post_anchors  = 0
        @skipped_no_mapping    = 0
        @skipped_blank_seo     = 0
        @skipped_url_collision = 0

        create_topic_permalinks
        create_category_permalinks
        create_post_anchor_permalinks
    end

    def create_topic_permalinks
        puts "  Processing topics..."

        rows = mysql_query!(
            "SELECT tid, title_seo FROM #{TABLE_PREFIX}forums_topics ORDER BY tid ASC"
        )

        rows.each do |row|
            tid       = row["tid"]
            title_seo = row["title_seo"].to_s.strip

            topic_id = topic_lookup_from_imported_post_id("t-#{tid}")&.dig(:topic_id)

            unless topic_id
                @skipped_no_mapping += 1
                next
            end

            # -----------------------------------------------------------------
            # A) Legacy query-string URL: index.php?showtopic=TID
            #
            # Discourse joins the request path and query string before lookup:
            #   url = "index.php?showtopic=#{tid}"
            # No leading slash. This is the pattern causing the 404s.
            # -----------------------------------------------------------------
            legacy_url = "index.php?showtopic=#{tid}"
            create_permalink(legacy_url, topic_id: topic_id)
            @added_topics_legacy += 1

            # -----------------------------------------------------------------
            # B) IPS4 pretty-URL variants (topic/TID-slug)
            #
            # Skip if the slug is blank — a malformed permalink would never
            # match anything and would waste a DB row.
            # -----------------------------------------------------------------
            if title_seo.empty?
                @skipped_blank_seo += 1
            else
                pretty_slash    = "topic/#{tid}-#{title_seo}/"
                pretty_no_slash = "topic/#{tid}-#{title_seo}"
                create_permalink(pretty_slash,    topic_id: topic_id)
                create_permalink(pretty_no_slash, topic_id: topic_id)
                @added_topics_pretty += 2
            end
        end
    end

    def create_category_permalinks
        puts "  Processing categories/forums..."

        rows = mysql_query!(
            "SELECT id, name_seo FROM #{TABLE_PREFIX}forums_forums ORDER BY id ASC"
        )

        rows.each do |row|
            forum_id = row["id"]
            name_seo = row["name_seo"].to_s.strip

            category_id = category_id_from_imported_category_id(forum_id)

            unless category_id
                @skipped_no_mapping += 1
                next
            end

            # -----------------------------------------------------------------
            # A) Legacy query-string URL: index.php?showforum=ID
            # -----------------------------------------------------------------
            legacy_url = "index.php?showforum=#{forum_id}"
            create_permalink(legacy_url, category_id: category_id)
            @added_cats_legacy += 1

            # -----------------------------------------------------------------
            # B) IPS4 pretty-URL variants (forum/ID-slug)
            # -----------------------------------------------------------------
            if name_seo.empty?
                @skipped_blank_seo += 1
            else
                pretty_slash    = "forum/#{forum_id}-#{name_seo}/"
                pretty_no_slash = "forum/#{forum_id}-#{name_seo}"
                create_permalink(pretty_slash,    category_id: category_id)
                create_permalink(pretty_no_slash, category_id: category_id)
                @added_cats_pretty += 2
            end
        end
    end

    # -------------------------------------------------------------------------
    # Phase 2C: Post anchor redirects (index.php?showtopic=TID&p=PID)
    #
    # IPS4 links often include &p=PID pointing at a specific reply. Discourse
    # permalink matching uses the full query string, so each combination needs
    # its own record.
    #
    # Each record uses Permalink#external_url to redirect to the exact post:
    #   index.php?showtopic=47375&p=123456  →  /t/topic-slug/47375/8
    #
    # IPS4 stores first posts (new_topic = 1) under the topic ID ("t-TID") and
    # replies (new_topic = 0) under their own post ID. Both are resolved to the
    # correct Discourse post so post_number is always accurate.
    #
    # Controlled by:
    #   permalink_options.create_post_anchor_redirects  — enable/disable this phase
    #   permalink_options.force_update_post_anchors     — overwrite existing records
    #     (use after a previous run that only created topic-level redirects)
    # -------------------------------------------------------------------------
    def create_post_anchor_permalinks
        return unless CONFIG.dig("permalink_options", "create_post_anchor_redirects")

        force_update = CONFIG.dig("permalink_options", "force_update_post_anchors")

        puts "  Processing post anchors (index.php?showtopic=TID&p=PID → /t/slug/TID/N)..."
        puts "  Force-updating existing records." if force_update

        topic_cache = {}  # Discourse topic_id → Topic — avoids N+1 on post.topic
        last_pid    = -1

        loop do
            rows = mysql_query!(<<~SQL)
                SELECT pid, topic_id AS tid, new_topic
                FROM #{TABLE_PREFIX}forums_posts
                WHERE pdelete_time = 0
                  AND queued = 0
                  AND pid > #{last_pid}
                ORDER BY pid ASC
                LIMIT 5000
            SQL

            break if rows.empty?

            last_pid = rows.last["pid"]

            rows.each do |row|
                pid       = row["pid"]
                tid       = row["tid"]
                new_topic = row["new_topic"].to_i == 1

                # First posts are imported with "t-TID"; replies are imported with pid.
                imported_id = new_topic ? "t-#{tid}" : pid
                post_id     = post_id_from_imported_post_id(imported_id)
                next unless post_id

                post = Post.find_by(id: post_id)
                next unless post

                topic = topic_cache[post.topic_id] ||= post.topic
                next unless topic

                legacy_url = "index.php?showtopic=#{tid}&p=#{pid}"
                target_url = "/t/#{topic.slug}/#{topic.id}/#{post.post_number}"

                upsert_post_anchor_permalink(legacy_url, target_url, force: force_update)
            end

            print "\r    #{@added_post_anchors + @updated_post_anchors} records processed..."
            STDOUT.flush
        end

        puts "\r    Post anchors — created: #{@added_post_anchors}, updated: #{@updated_post_anchors}        "
    end

    def print_summary
        summary = [
            "",
            "=== Summary ===",
            "  Topics:",
            "    Legacy (showtopic) created : #{@added_topics_legacy}",
            "    Pretty-URL created         : #{@added_topics_pretty}",
            "  Categories:",
            "    Legacy (showforum) created : #{@added_cats_legacy}",
            "    Pretty-URL created         : #{@added_cats_pretty}",
            "  Post anchors (showtopic&p=)  : created #{@added_post_anchors}, updated #{@updated_post_anchors}#{" (disabled)" if !CONFIG.dig("permalink_options", "create_post_anchor_redirects")}",
            "  Skipped (no Discourse mapping): #{@skipped_no_mapping}",
            "  Skipped (blank SEO slug)      : #{@skipped_blank_seo}",
            "  Skipped (URL collision)       : #{@skipped_url_collision} — redirect covered by existing record",
            "",
            "Done.",
        ]

        summary.each { |line| puts line }

        if @log_file
            @log_file.puts ""
            @log_file.puts "# --- Summary ---"
            summary.each { |line| @log_file.puts "# #{line}" }
        end
    end

    private

    # Writes a timestamped info line to both stdout and the log file.
    def log_info(message)
        puts message
        @log_file&.puts "[#{Time.now.strftime("%Y-%m-%d %H:%M:%S")}] #{message}"
    end

    # Writes a timestamped error line to both stdout and the log file.
    def log_error(message)
        puts message
        @log_file&.puts "[#{Time.now.strftime("%Y-%m-%d %H:%M:%S")}] ERROR #{message}"
    end

    # Creates or updates a post-anchor Permalink record.
    # Uses Permalink#external_url so the redirect lands on the exact post
    # (/t/slug/TID/POST_NUMBER) rather than the topic root.
    #
    # When force: true, an existing record is overwritten — this is the upgrade
    # path from a previous run that only created topic_id-level redirects.
    def upsert_post_anchor_permalink(url, target_url, force: false)
        existing = Permalink.find_by(url: url)

        if existing
            return unless force

            begin
                existing.update!(external_url: target_url, topic_id: nil, category_id: nil)
                @updated_post_anchors += 1
                log_info "  UPDATED anchor: #{url}  →  #{target_url}"
            rescue ActiveRecord::RecordInvalid => e
                @skipped_url_collision += 1
                log_error "  COLLISION (anchor update): #{url} — #{e.message}"
            end
            return
        end

        begin
            Permalink.create!(url: url, external_url: target_url)
            @added_post_anchors += 1
            log_info "  CREATED anchor: #{url}  →  #{target_url}"
        rescue ActiveRecord::RecordInvalid => e
            @skipped_url_collision += 1
            log_error "  COLLISION (anchor create RecordInvalid): #{url} — #{e.message}"
        rescue ActiveRecord::RecordNotUnique
            @skipped_url_collision += 1
            log_error "  COLLISION (anchor create RecordNotUnique): #{url}"
        end
    end

    # Creates a Permalink only if one does not already exist for that url.
    # Uses Permalink.create! so model validations (including Discourse's own
    # URL normalization) run. Duplicate entries are silently skipped.
    def create_permalink(url, topic_id: nil, category_id: nil)
        if Permalink.exists?(url: url)
            @skipped_url_collision += 1
            log_info "  SKIP (exists): #{url}"
            return
        end

        attrs = { url: url }
        attrs[:topic_id]    = topic_id    if topic_id
        attrs[:category_id] = category_id if category_id

        begin
            Permalink.create!(attrs)
            target = topic_id ? "topic_id=#{topic_id}" : "category_id=#{category_id}"
            log_info "  CREATED: #{url}  →  #{target}"
        rescue ActiveRecord::RecordInvalid => e
            # Discourse normalizes URLs before saving (strips/replaces special chars like
            # em-dashes). Two different IPS4 slugs can normalize to the same stored value,
            # causing a collision that exists?() does not catch. Harmless — the existing
            # record already provides the redirect.
            @skipped_url_collision += 1
            log_error "  COLLISION (RecordInvalid): #{url} — #{e.message}"
        rescue ActiveRecord::RecordNotUnique
            # Race between exists? check and create — harmless, skip.
            @skipped_url_collision += 1
            log_error "  COLLISION (RecordNotUnique): #{url}"
        end
    end

    # Executes a MySQL query and returns the result rows with UTF-8 encoding
    # enforced on all string values.
    #
    # Unlike the original mysql_query helper, this raises on error rather than
    # silently returning [] — a silent empty result would cause the script to
    # report success while skipping all data.
    def mysql_query!(sql)
        results = @client.query(sql, cache_rows: true)

        results.map do |row|
            row.each_with_object({}) do |(k, v), h|
                if v.is_a?(String)
                    v = v.dup.force_encoding("UTF-8")
                    v = v.encode("UTF-8", invalid: :replace, undef: :replace, replace: "") unless v.valid_encoding?
                end
                h[k] = v
            end
        end
    rescue Mysql2::Error => e
        raise "MySQL query failed: #{e.message}\nSQL: #{sql}"
    end
end

ImportScripts::IPBoard4PermalinkFixer.new.execute
