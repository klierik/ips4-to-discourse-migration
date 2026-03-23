# frozen_string_literal: true

require "mysql2"
require "reverse_markdown"
require "yaml"
require "fileutils"
require File.expand_path('/var/www/discourse/script/import_scripts/base.rb')

class ImportScripts::IPBoard4PostUpdater < ImportScripts::Base
    # Try different config paths just in case the script is placed inside script/import_scripts directly
    # Config search priority: first /shared/ (Docker volume), then next to the script
    CONFIG_PATHS = [
        File.expand_path("/shared/ipboard4-migration/ipboard4_config.yml"),
        File.expand_path("/shared/ipboard4_config.yml"),
        File.expand_path(File.dirname(__FILE__) + "/ipboard4-migration/ipboard4_config.yml"),
        File.expand_path(File.dirname(__FILE__) + "/ipboard4_config.yml"),
    ]
    CONFIG_PATH = CONFIG_PATHS.find { |p| File.exist?(p) } || (raise "Could not find ipboard4_config.yml")
    CONFIG = YAML.load_file(CONFIG_PATH)

    BATCH_SIZE = CONFIG.dig("import", "batch_size") || 5000
    UPLOADS_DIR = CONFIG.dig("import", "uploads_dir") || "/mnt/ips4_uploads"
    TABLE_PREFIX = CONFIG.dig("database", "table_prefix") || "ibf2_"
    WIPE_REVISIONS = CONFIG.dig("import", "wipe_revisions") == true

    EMOTICON_MAPPING = {
        "angry"       => "😠",
        "biggrin"     => "😁",
        "blink"       => "😳",
        "blush"       => "😊",
        "cool"        => "😎",
        "dry"         => "😒",
        "excl"        => "❗",
        "facepalmxd"  => "🤦‍♂️",
        "happy"       => "😀",
        "huh"         => "😕",
        "laugh"       => "😂",
        "mellow"      => "😐",
        "ohmy"        => "😮",
        "ph34r"       => "🥷",
        "rolleyes"    => "🙄",
        "sad"         => "😢",
        "sleep"       => "😴",
        "smile"       => "🙂",
        "tongue"      => "😛",
        "unsure"      => "🫤",
        "wacko"       => "🤪",
        "wink"        => "😉",
        "wub"         => "😍"
    }.freeze

    def initialize
        super

        @client = Mysql2::Client.new(
            host: ENV["DB_HOST"] || CONFIG.dig("database", "host") || "localhost",
            username: ENV["DB_USER"] || CONFIG.dig("database", "username") || "root",
            password: ENV.has_key?("DB_PW") ? ENV["DB_PW"] : CONFIG.dig("database", "password").to_s,
            database: ENV["DB_NAME"] || CONFIG.dig("database", "name") || "ips4",
            port: CONFIG.dig("database", "port") || 3306
        )

        # Read ID for debugging
        @debug_post_id = ENV["DEBUG_POST_ID"]&.to_i || CONFIG.dig("debug", "single_post_id")

        @client.query("SET NAMES utf8mb4")
        Regexp.timeout = 5

        website_config = CONFIG.dig("website")
        if website_config.is_a?(Hash)
            @old_domain         = website_config["old_domain"].to_s
            @new_domain         = website_config["new_domain"].to_s
            @resolve_internal_links = @old_domain.present? && @new_domain.present?
            @old_domain_escaped = Regexp.escape(@old_domain) if @resolve_internal_links
        else
            @resolve_internal_links = false
            @old_domain = nil
            @new_domain = nil
        end
    end

    def execute
        puts "Starting post updates based on new parser..."
        puts "Using config from: #{CONFIG_PATH}"

        log_dir   = "/shared/ipboard4-migration/logs"
        FileUtils.mkdir_p(log_dir)
        @log_path = File.join(log_dir, "import_posts_#{Time.now.strftime("%Y-%m-%d_%H-%M-%S")}.log")
        @log_file = File.open(@log_path, "w")
        @log_file.sync = true
        @log_file.puts "# ipboard4_import_posts_only — #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}"
        @log_file.puts "# Config: #{CONFIG_PATH}"
        @log_file.puts ""
        puts "Log: #{@log_path}"

        # Temporarily relax Discourse attachment constraints during import
        current_extensions = SiteSetting.authorized_extensions.to_s
        new_extensions = CONFIG.dig("import", "allowed_extensions") || ["zip", "rar", "7z", "tar", "gz"]
        puts "Config allowed_extensions: #{new_extensions.inspect}"
        combined_extensions = (current_extensions.split("|") + new_extensions).uniq.join("|")
        SiteSetting.authorized_extensions = combined_extensions
        puts "Authorized extensions set to: #{SiteSetting.authorized_extensions}"

        max_size = CONFIG.dig("import", "max_attachment_size_kb") || 262144
        SiteSetting.max_attachment_size_kb = max_size
        puts "Max attachment size set to: #{max_size} KB"

        # Permit iframes from known embed providers so <iframe> tags survive post cooking
        current_iframes      = SiteSetting.allowed_iframes.to_s
        @allowed_iframe_domains = CONFIG.dig("import", "allowed_iframe_domains") || ["https://jsfiddle.net/", "https://codepen.io/"]
        combined_iframes     = (current_iframes.split("|") + @allowed_iframe_domains).uniq.join("|")
        SiteSetting.allowed_iframes = combined_iframes
        puts "Allowed iframes set to: #{SiteSetting.allowed_iframes}"

        @started_at = Time.now
        @stats = {}

        update_posts
        update_topics_first_posts
        update_message_posts

        st = @stats[:topics] || { processed: 0, revised: 0, identical: 0, skipped: 0 }
        sp = @stats[:posts]  || { processed: 0, revised: 0, identical: 0, skipped: 0 }
        sm = @stats[:pms]    || { processed: 0, revised: 0, identical: 0, skipped: 0 }

        total_processed = st[:processed] + sp[:processed] + sm[:processed]
        total_revised   = st[:revised]   + sp[:revised]   + sm[:revised]
        total_identical = st[:identical] + sp[:identical] + sm[:identical]
        total_skipped   = st[:skipped]   + sp[:skipped]   + sm[:skipped]

        elapsed = (Time.now - @started_at).to_i
        h, rem  = elapsed.divmod(3600)
        m, s    = rem.divmod(60)

        puts ""
        puts "=" * 80
        puts "  Final Summary"
        puts "-" * 80
        puts format("  %-22s %s", "Elapsed time:", format("%02d:%02d:%02d", h, m, s))
        puts "-" * 80
        puts format("  %-22s %11s %11s %11s %11s", "Section", "Processed", "Revised", "Identical", "Skipped")
        puts "-" * 80
        puts format("  %-22s %11d %11d %11d %11d", "Topic first posts", st[:processed], st[:revised], st[:identical], st[:skipped])
        puts format("  %-22s %11d %11d %11d %11d", "Standard posts",    sp[:processed], sp[:revised], sp[:identical], sp[:skipped])
        puts format("  %-22s %11d %11d %11d %11d", "Private messages",  sm[:processed], sm[:revised], sm[:identical], sm[:skipped])
        puts "-" * 80
        puts format("  %-22s %11d %11d %11d %11d", "TOTAL", total_processed, total_revised, total_identical, total_skipped)
        puts "=" * 80
        puts "  Revised   — content changed, update_columns written"
        puts "  Identical — content unchanged, no write"
        puts "  Skipped   — IPS4 post not found in Discourse (not imported)"
        puts "-" * 80
        puts "  Run the following rake tasks to rebuild derived data:"
        puts "    RAILS_ENV=production bundle exec rake posts:rebake"
        puts "    RAILS_ENV=production bundle exec rake users:recalculate_post_counts"
        puts "=" * 80

        if @log_file
            @log_file.puts ""
            @log_file.puts "# --- Summary ---"
            @log_file.puts "# Elapsed             : #{format("%02d:%02d:%02d", h, m, s)}"
            @log_file.puts "# Topics processed    : #{st[:processed]}"
            @log_file.puts "# Topics revised      : #{st[:revised]}"
            @log_file.puts "# Posts processed     : #{sp[:processed]}"
            @log_file.puts "# Posts revised       : #{sp[:revised]}"
            @log_file.puts "# PMs processed       : #{sm[:processed]}"
            @log_file.puts "# PMs revised         : #{sm[:revised]}"
            @log_file.close
            puts "Log: #{@log_path}"
        end
    end

    def update_topics_first_posts
        puts "", "updating first posts of topics..."
    
        last_topic_id = -1
        total_revised = 0
        total_identical = 0
        total_skipped = 0
        total_processed = 0

        total_topics = mysql_query(<<~SQL).first["count"]
            SELECT COUNT(*) AS count
            FROM #{TABLE_PREFIX}forums_topics t
            JOIN #{TABLE_PREFIX}forums_posts p ON t.tid = p.topic_id
            WHERE t.topic_close_time = 0
            AND p.pdelete_time = 0
            AND p.new_topic = 1
            AND t.approved = 1
            AND p.queued = 0
        SQL

        batches(BATCH_SIZE) do |offset|
            topics = mysql_query(<<~SQL).to_a
                SELECT t.tid AS id, t.starter_id, p.post
                FROM #{TABLE_PREFIX}forums_topics t
                JOIN #{TABLE_PREFIX}forums_posts p ON t.tid = p.topic_id
                WHERE t.topic_close_time = 0
                AND p.pdelete_time = 0
                AND p.new_topic = 1
                AND t.approved = 1
                AND p.queued = 0
                AND tid > #{last_topic_id}
                ORDER BY t.tid
                LIMIT #{BATCH_SIZE}
            SQL

            break if topics.empty?

            last_topic_id = topics[-1]["id"]

            # Bulk-fetch all Discourse posts for this batch in one query
            batch_html = topics.map { |t| t["post"] }
            @attachment_cache       = build_attachment_cache(batch_html)
            @quote_post_cache       = build_quote_post_cache(batch_html)
            @mention_username_cache = build_mention_username_cache(batch_html)
            @topic_link_cache       = build_topic_link_cache(batch_html)

            discourse_post_ids = topics.filter_map { |t| post_id_from_imported_post_id("t-#{t["id"]}") }
            discourse_posts_by_id = Post.where(id: discourse_post_ids).includes(:user).index_by(&:id)

            topics.each_with_index do |t, index|
                total_processed += 1

                post_id = post_id_from_imported_post_id("t-#{t["id"]}")
                unless post_id
                    total_skipped += 1
                    next
                end

                if @debug_post_id.to_i > 0
                    next unless post_id == @debug_post_id
                end

                post = discourse_posts_by_id[post_id]
                next unless post

                user_id = user_id_from_imported_user_id(t["starter_id"]) || Discourse.system_user.id
                @current_post_context = "IPS4 topic t-#{t["id"]} → Discourse post ##{post_id} (/t/#{post.topic_id}/#{post.post_number})"
                raw = clean_up(t["post"], user_id)

                if @debug_post_id.to_i > 0
                    changed = raw != post.raw
                    puts ""
                    puts "=" * 80
                    puts "  DEBUG: Discourse post ##{post_id} (topic first post)"
                    puts "  Topic: #{post.topic_id}  |  Post ##{post.post_number}  |  Author: #{post.user&.username || "(unknown)"}"
                    puts "  Result: #{changed ? "CHANGED — saving" : "IDENTICAL — no update needed"}"
                    puts "=" * 80
                    puts ""
                    puts "--- IPS4 SOURCE HTML ---"
                    puts t["post"]
                    puts ""
                    puts "--- OLD RAW (current in Discourse) ---"
                    puts post.raw
                    puts ""
                    puts "--- NEW RAW (after clean_up) ---"
                    puts raw
                    puts "=" * 80
                    update_post_raw(post, raw) if changed
                    exit
                end

                if raw == post.raw
                    total_identical += 1
                    next
                end

                update_post_raw(post, raw)
                total_revised += 1

                if total_processed % 20 == 0 || total_processed == total_topics
                  print "\rProcessing topic #{total_processed}/#{total_topics} | Revised: #{total_revised} | Identical: #{total_identical} | Skipped: #{total_skipped}"
                  STDOUT.flush
                end
            end
        end
        puts "\nFinished topic first posts: revised=#{total_revised}, identical=#{total_identical}, skipped=#{total_skipped}"
        @stats[:topics] = { processed: total_processed, revised: total_revised, identical: total_identical, skipped: total_skipped }
    end

    def update_posts
        puts "", "updating standard posts..."
    
        last_post_id = -1
        total_revised = 0
        total_identical = 0
        total_skipped = 0
        total_processed = 0

        total_posts = mysql_query(<<~SQL).first["count"]
            SELECT COUNT(*) AS count
            FROM #{TABLE_PREFIX}forums_posts
            WHERE new_topic = 0
                AND pdelete_time = 0
                AND queued = 0
        SQL

        batches(BATCH_SIZE) do |offset|
            posts = mysql_query(<<~SQL).to_a
                SELECT pid AS id, author_id, post
                FROM #{TABLE_PREFIX}forums_posts
                WHERE new_topic = 0
                AND pdelete_time = 0
                AND queued = 0
                AND pid > #{last_post_id}
                ORDER BY pid
                LIMIT #{BATCH_SIZE}
            SQL
    
            break if posts.empty?

            last_post_id = posts[-1]["id"]

            # Bulk-fetch all Discourse posts for this batch in one query
            batch_html = posts.map { |p| p["post"] }
            @attachment_cache       = build_attachment_cache(batch_html)
            @quote_post_cache       = build_quote_post_cache(batch_html)
            @mention_username_cache = build_mention_username_cache(batch_html)
            @topic_link_cache       = build_topic_link_cache(batch_html)

            discourse_post_ids = posts.filter_map { |p| post_id_from_imported_post_id(p["id"]) }
            discourse_posts_by_id = Post.where(id: discourse_post_ids).includes(:user).index_by(&:id)

            posts.each_with_index do |p, index|
                total_processed += 1
                post_id = post_id_from_imported_post_id(p["id"])
                unless post_id
                    total_skipped += 1
                    next
                end

                if @debug_post_id.to_i > 0
                    next unless post_id == @debug_post_id
                    puts "\n[DEBUG MODE] Processing ONLY post #{post_id}"
                end

                post = discourse_posts_by_id[post_id]
                next unless post

                user_id = user_id_from_imported_user_id(p["author_id"]) || Discourse.system_user.id
                @current_post_context = "IPS4 post #{p["id"]} → Discourse post ##{post_id} (/t/#{post.topic_id}/#{post.post_number})"
                raw = clean_up(p["post"], user_id)

                if @debug_post_id.to_i > 0
                    changed = raw != post.raw
                    puts ""
                    puts "=" * 80
                    puts "  DEBUG: Discourse post ##{post_id}"
                    puts "  Topic: #{post.topic_id}  |  Post ##{post.post_number}  |  Author: #{post.user&.username || "(unknown)"}"
                    puts "  Result: #{changed ? "CHANGED — saving" : "IDENTICAL — no update needed"}"
                    puts "=" * 80
                    puts ""
                    puts "--- IPS4 SOURCE HTML ---"
                    puts p["post"]
                    puts ""
                    puts "--- OLD RAW (current in Discourse) ---"
                    puts post.raw
                    puts ""
                    puts "--- NEW RAW (after clean_up) ---"
                    puts raw
                    puts "=" * 80
                    update_post_raw(post, raw) if changed
                    exit
                end

                if raw == post.raw
                    total_identical += 1
                    next
                end

                update_post_raw(post, raw)
                total_revised += 1

                if total_processed % 20 == 0 || total_processed == total_posts
                  print "\rProcessing post #{total_processed}/#{total_posts} | Revised: #{total_revised} | Identical: #{total_identical} | Skipped: #{total_skipped}"
                  STDOUT.flush
                end
            end
        end
        puts "\nFinished standard posts: revised=#{total_revised}, identical=#{total_identical}, skipped=#{total_skipped}"
        @stats[:posts] = { processed: total_processed, revised: total_revised, identical: total_identical, skipped: total_skipped }
    end

    def update_message_posts
        puts "", "updating private message posts..."
        
        last_msg_id = -1
        total_revised = 0
        total_identical = 0
        total_skipped = 0
        total_processed = 0

        total_msg_posts = mysql_query("SELECT COUNT(*) AS count FROM #{TABLE_PREFIX}core_message_posts").first["count"]

        batches(BATCH_SIZE) do |offset|
            msg_posts = mysql_query(<<~SQL).to_a
                SELECT msg_id AS id, msg_author_id AS author_id, msg_post AS post
                FROM #{TABLE_PREFIX}core_message_posts
                WHERE msg_id > #{last_msg_id}
                ORDER BY msg_id
                LIMIT #{BATCH_SIZE}
            SQL

            break if msg_posts.empty?
            last_msg_id = msg_posts.last["id"]

            # Bulk-fetch all Discourse posts for this batch in one query
            batch_html = msg_posts.map { |mp| mp["post"] }
            @attachment_cache       = build_attachment_cache(batch_html)
            @quote_post_cache       = build_quote_post_cache(batch_html)
            @mention_username_cache = build_mention_username_cache(batch_html)
            @topic_link_cache       = build_topic_link_cache(batch_html)

            discourse_post_ids = msg_posts.filter_map { |mp| post_id_from_imported_post_id("mp-#{mp["id"]}") }
            discourse_posts_by_id = Post.where(id: discourse_post_ids).includes(:user).index_by(&:id)

            msg_posts.each_with_index do |mp, index|
                total_processed += 1
                post_id = post_id_from_imported_post_id("mp-#{mp["id"]}")
                unless post_id
                    total_skipped += 1
                    next
                end

                if @debug_post_id.to_i > 0
                    next unless post_id == @debug_post_id
                end

                post = discourse_posts_by_id[post_id]
                next unless post

                user_id = user_id_from_imported_user_id(mp["author_id"]) || Discourse.system_user.id
                @current_post_context = "IPS4 PM post mp-#{mp["id"]} → Discourse post ##{post_id}"
                raw = clean_up(mp["post"], user_id)

                if @debug_post_id.to_i > 0
                    changed = raw != post.raw
                    puts ""
                    puts "=" * 80
                    puts "  DEBUG: Discourse post ##{post_id} (private message)"
                    puts "  Topic: #{post.topic_id}  |  Post ##{post.post_number}  |  Author: #{post.user&.username || "(unknown)"}"
                    puts "  Result: #{changed ? "CHANGED — saving" : "IDENTICAL — no update needed"}"
                    puts "=" * 80
                    puts ""
                    puts "--- IPS4 SOURCE HTML ---"
                    puts mp["post"]
                    puts ""
                    puts "--- OLD RAW (current in Discourse) ---"
                    puts post.raw
                    puts ""
                    puts "--- NEW RAW (after clean_up) ---"
                    puts raw
                    puts "=" * 80
                    update_post_raw(post, raw) if changed
                    exit
                end

                if raw == post.raw
                    total_identical += 1
                    next
                end

                update_post_raw(post, raw)
                total_revised += 1

                if total_processed % 20 == 0 || total_processed == total_msg_posts
                  print "\rProcessing msg #{total_processed}/#{total_msg_posts} | Revised: #{total_revised} | Identical: #{total_identical} | Skipped: #{total_skipped}"
                  STDOUT.flush
                end
            end
        end
        puts "\nFinished private messages: revised=#{total_revised}, identical=#{total_identical}, skipped=#{total_skipped}"
        @stats[:pms] = { processed: total_processed, revised: total_revised, identical: total_identical, skipped: total_skipped }
    end

    # Write message to both stdout and the log file.
    # Used for non-fatal errors (missing files, failed uploads) inside clean_up.
    def log_error(message)
        puts message
        @log_file&.puts "[#{Time.now.strftime("%Y-%m-%d %H:%M:%S")}] #{message.lstrip}"
    end

    # ---------------------------------------------------------------------------
    # Per-batch cache builders — call once per batch before iterating posts.
    # Each method scans the raw HTML strings to collect all IDs, then resolves
    # them in a single bulk query instead of one query per post/element.
    # ---------------------------------------------------------------------------

    def build_topic_link_cache(batch_html)
        return {} unless @resolve_internal_links

        topic_ids = []
        batch_html.each do |html|
            next unless html
            html.scan(/[?&]showtopic=(\d+)/) { topic_ids << $1.to_i }
            html.scan(%r{/topic/(\d+)-}) { topic_ids << $1.to_i }
        end
        return {} if topic_ids.empty?

        ips4_tid_to_post_id = topic_ids.uniq.each_with_object({}) do |tid, h|
            post_id = post_id_from_imported_post_id("t-#{tid}")
            h[tid] = post_id if post_id
        end
        return {} if ips4_tid_to_post_id.empty?

        posts_by_id = Post.where(id: ips4_tid_to_post_id.values).includes(:topic).index_by(&:id)

        ips4_tid_to_post_id.each_with_object({}) do |(tid, post_id), h|
            post = posts_by_id[post_id]
            h[tid] = post.topic if post&.topic
        end
    end

    def build_attachment_cache(batch_html)
        attach_ids = []
        batch_html.each do |html|
            next unless html
            html.scan(/attach_id=(\d+)/) { attach_ids << $1.to_i }
            html.scan(%r{attachment\.php\?id=(\d+)}) { attach_ids << $1.to_i }
        end
        return {} if attach_ids.empty?

        mysql_query(
            "SELECT attach_id, attach_file, attach_location
             FROM #{TABLE_PREFIX}core_attachments
             WHERE attach_id IN (#{attach_ids.uniq.join(',')})"
        ).each_with_object({}) { |row, h| h[row["attach_id"]] = row }
    end

    def build_quote_post_cache(batch_html)
        comment_ids = []
        batch_html.each do |html|
            next unless html
            html.scan(/data-ipsquote-contentcommentid="(\d+)"/) { comment_ids << $1 }
            html.scan(/data-cid="(\d+)"/) { comment_ids << $1 }
        end
        return {} if comment_ids.empty?

        discourse_ids = comment_ids.uniq.filter_map { |cid| post_id_from_imported_post_id(cid) }
        return {} if discourse_ids.empty?

        Post.where(id: discourse_ids).includes(:user).index_by(&:id)
    end

    def build_mention_username_cache(batch_html)
        ips_user_ids = []
        batch_html.each do |html|
            next unless html
            html.scan(%r{/profile/(\d+)-}) { ips_user_ids << $1 }
        end
        return {} if ips_user_ids.empty?

        discourse_ids = ips_user_ids.uniq.filter_map { |uid| user_id_from_imported_user_id(uid) }
        return {} if discourse_ids.empty?

        User.where(id: discourse_ids).pluck(:id, :username).to_h
    end

    # Lightweight post update — skips the full post.revise callback chain
    # (Sidekiq jobs, MessageBus, PostRevision, topic_links, quoted_posts, etc.).
    # Run `rake posts:rebake` and `rake topics:fix_counts` after the script finishes.
    def update_post_raw(post, raw)
        cooked = post.cook(raw)
        post.update_columns(
            raw:           raw,
            cooked:        cooked,
            baked_at:      Time.zone.now,
            baked_version: Post::BAKED_VERSION,
        )
        if WIPE_REVISIONS
            PostRevision.where(post_id: post.id).delete_all
            post.update_columns(version: 1, public_version: 1)
        end
    end

    # Replace emoticon <img> tags inside a Nokogiri node subtree in-place.
    # Called before extracting inner_html for blockquotes/spoilers so that
    # emoticons are resolved to Unicode before ReverseMarkdown sees the HTML.
    def process_emoticons_in_node(node)
        node.css("img[src*='fileStore.core_Emoticons'], img[src*='/uploads/emoticons']").each do |img|
            src = img["src"].to_s
            filename = File.basename(src)
            core_name = filename.downcase.sub(/^default_/, '').sub(/@2x\.png$/, '').sub(/\.(png|gif)$/, '')
            emoji = EMOTICON_MAPPING[core_name] || "🙂"
            img.replace(emoji)
        end
    end

    # Returns true if the given iframe URL is covered by an allowed_iframe_domains prefix.
    # Normalises protocol-relative URLs (//domain.com/...) to https: before comparing.
    def iframe_allowed?(url)
        return false unless @allowed_iframe_domains&.any?
        normalized = url.start_with?("//") ? "https:#{url}" : url
        @allowed_iframe_domains.any? { |prefix| normalized.start_with?(prefix) }
    end

    # Replace allowed <iframe> tags inside a Nokogiri node subtree with placeholders.
    # Called before extracting inner_html for blockquotes/spoilers so that iframes inside
    # quoted content are preserved as live embeds rather than being reduced to plain-text URLs
    # by ReverseMarkdown. Placeholders are restored after the main ReverseMarkdown pass.
    def process_iframes_in_node(node)
        node.css("iframe").each do |iframe|
            url = iframe["data-embed-src"] || iframe["src"]
            next unless url
            next unless iframe_allowed?(url)

            clean_src  = url.start_with?("//") ? "https:#{url}" : url
            width      = iframe["width"]&.strip || "100%"
            height     = iframe["height"]&.strip || "300"
            iframe_tag = "<iframe src=\"#{CGI.escapeHTML(clean_src)}\" width=\"#{CGI.escapeHTML(width)}\" height=\"#{CGI.escapeHTML(height)}\" frameborder=\"0\" allowfullscreen=\"allowfullscreen\"></iframe>"
            placeholder = "XIFRX#{@iframe_placeholders.size}X"
            @iframe_placeholders[placeholder] = "\n#{iframe_tag}\n"
            iframe.replace(placeholder)
        end
    end

    def clean_up(raw, user_id = -1)
        return if raw.nil?

        begin
            raw.encode!("utf-8", "utf-8", invalid: :replace, undef: :replace, replace: "")
            raw.gsub!(%r{<(.+)>&nbsp;</\1>}, "\n\n")
    
        rescue Regexp::TimeoutError => e
            log_error "Regex Timeout Error while processing text: #{raw[0..100]}..."
            return
        end
      
        doc = Nokogiri::HTML5.fragment(raw)

        # -------------------------------------------------------
        # Quote handling: use placeholders to protect [quote] BBCode from ReverseMarkdown.
        # ReverseMarkdown escapes underscores in plain text, so placeholders must use
        # only alphanumeric characters — no underscores, percent signs, or other
        # Markdown-special characters that would break the gsub match after conversion.
        # -------------------------------------------------------
        @quote_placeholders  ||= {}
        @iframe_placeholders ||= {}

        # Handle IPS4 linked quotes: blockquote.ipsQuote
        doc.css("blockquote.ipsQuote").each_with_index do |bq, idx|
            ips_comment_id = bq["data-ipsquote-contentcommentid"]
            ips_username   = bq["data-ipsquote-username"].to_s.strip

            # Remove the citation div (contains relative time text like "18 hours ago")
            bq.css(".ipsQuote_citation").each(&:remove)

            # The actual quoted text lives in .ipsQuote_contents
            contents_node = bq.at_css(".ipsQuote_contents")
            inner_node = contents_node || bq
            process_emoticons_in_node(inner_node)
            process_iframes_in_node(inner_node)

            # Convert inner content to markdown separately
            inner_md = ReverseMarkdown.convert(inner_node.inner_html.strip).strip

            discourse_post_id = post_id_from_imported_post_id(ips_comment_id) if ips_comment_id.present?
            post = @quote_post_cache[discourse_post_id] if discourse_post_id

            if post
                quote_bbcode = "\n\n[quote=\"#{post.user.username},post:#{post.post_number},topic:#{post.topic_id}\"]\n#{inner_md}\n[/quote]\n\n"
            elsif ips_username.present?
                quote_bbcode = "\n\n[quote=\"#{ips_username}\"]\n#{inner_md}\n[/quote]\n\n"
            else
                quote_bbcode = "\n\n[quote]\n#{inner_md}\n[/quote]\n\n"
            end

            placeholder = "XQPX#{idx}XCIDX#{ips_comment_id}X"
            @quote_placeholders[placeholder] = quote_bbcode
            bq.replace(placeholder)
        end

        # Handle plain blockquotes: blockquote.ipsBlockquote
        doc.css("blockquote.ipsBlockquote").each_with_index do |bq, idx|
            post_id = post_id_from_imported_post_id(bq["data-cid"])
            if post = @quote_post_cache[post_id]
                process_emoticons_in_node(bq)
                process_iframes_in_node(bq)
                inner_md = ReverseMarkdown.convert(bq.inner_html).strip
                quote_bbcode = "\n\n[quote=\"#{post.user.username},post:#{post.post_number},topic:#{post.topic_id}\"]\n#{inner_md}\n[/quote]\n\n"
                placeholder = "XBQPX#{idx}X"
                @quote_placeholders[placeholder] = quote_bbcode
                bq.replace(placeholder)
            end
        end

        # Code block fix (IPS4 <pre class="ipsCode"> puts <br> tags instead of newlines sometimes)
        # First: strip prettyprint syntax-highlighting spans (pln/tag/atn/pun/atv classes)
        # so multi-line code blocks are not collapsed into a single line by ReverseMarkdown.
        doc.css("pre.ipsCode, pre.prettyprint").each do |code_block|
            code_block.content = code_block.text
        end
        doc.css("pre, code, .ipsCode").each do |code_block|
            code_block.inner_html = code_block.inner_html.gsub(/<br\s*\/?>/i, "\n")
        end

        # Handle IPS4 spoiler blocks: blockquote.ipsStyle_spoiler → [details="title"]...[/details]
        # Processed after code block fix so <br>→\n is already applied inside spoiler content.
        doc.css("blockquote.ipsStyle_spoiler").each_with_index do |bq, idx|
            header_node = bq.at_css(".ipsSpoiler_header span")
            title = header_node ? header_node.text.strip : "Spoiler"

            contents_node = bq.at_css(".ipsSpoiler_contents")
            inner_node = contents_node || bq
            process_emoticons_in_node(inner_node)
            process_iframes_in_node(inner_node)

            inner_md = ReverseMarkdown.convert(inner_node.inner_html.strip).strip

            spoiler_bbcode = "\n\n[details=\"#{title}\"]\n#{inner_md}\n[/details]\n\n"
            placeholder = "XSPX#{idx}X"
            @quote_placeholders[placeholder] = spoiler_bbcode
            bq.replace(placeholder)
        end

        doc.css("a").each do |a|
            href = a["href"].to_s
            img = a.previous_element if a.previous_element&.name == "img"

            # Resolve internal IPS4 topic links to Discourse topic URLs.
            # Detects: showtopic=N and /topic/N-slug/ patterns — with or without
            # <___base_url___> prefix or absolute old-domain URL.
            if @resolve_internal_links
                normalized = href
                    .sub("<___base_url___>", "")
                    .sub(/\Ahttps?:\/\/#{@old_domain_escaped}/, "")

                ips4_tid = nil
                ips4_tid = $1.to_i if normalized.match(/[?&]showtopic=(\d+)/)
                ips4_tid = $1.to_i if !ips4_tid && normalized.match(%r{\A/topic/(\d+)-})

                if ips4_tid && (topic = @topic_link_cache[ips4_tid])
                    new_href  = "/t/#{topic.slug}/#{topic.id}"
                    link_text = a.text.strip
                    if link_text.match?(/showtopic=|\/topic\/\d+/) || link_text.include?(@old_domain)
                        a.content = "#{@new_domain}#{new_href}"
                    end
                    a["href"] = new_href
                    next
                end
            end

            if href.start_with?("<___base_url___>/index.php?app=core&module=attach")
                if (match_data = href.match(/attach_id=(\d+)/))
                    attach_id = match_data[1].to_i
                    result = @attachment_cache[attach_id]
        
                    if result
                        original_path = File.join(UPLOADS_DIR, result["attach_location"])
                        directory = File.dirname(original_path)
                        filename = result["attach_file"].encode("UTF-8", invalid: :replace, undef: :replace, replace: "")

                        extname = File.extname(result["attach_location"])
                        basename = File.basename(result["attach_location"], extname)

                        new_filename = filename if File.extname(filename).length > 1
                        new_filename ||= "#{filename}#{extname}"
                        new_path = File.join(directory, new_filename)

                        if File.exist?(original_path) && !File.exist?(new_path)
                            File.rename(original_path, new_path)
                        end
        
                        if File.exist?(new_path)
                            begin
                                upload = create_upload(user_id, new_path, new_filename)
                                if upload&.persisted?
                                    new_url = html_for_upload(upload, new_filename)
                                    if img
                                        img.replace(new_url)
                                        img.remove_attribute("data-src")
                                        a.remove
                                    else
                                        a.replace(new_url)
                                    end
                                else
                                    error_msg = upload ? upload.errors.full_messages.join(', ') : "Upload object is nil"
                                    log_error "\nUpload persisted? false for attach_id #{attach_id} file #{new_filename}: #{error_msg} | #{@current_post_context}"
                                    a.replace("[Upload failed: #{new_filename}]")
                                end
                            rescue StandardError => e
                                log_error "\nError processing attachment link for attach_id #{attach_id} file #{new_filename}: #{e.message} | #{@current_post_context}"
                                a.replace("[Upload failed: #{new_filename}]")
                            end
                        else
                            log_error "\nMissing Attachment: #{new_path} for attach_id #{attach_id} | #{@current_post_context}"
                            a.replace("[Missing Attachment: #{new_filename}]")
                        end
                    else
                        log_error "\nMissing Attachment ID: #{attach_id} | #{@current_post_context}"
                        a.replace("[Missing Attachment ID: #{attach_id}]")
                    end
                end
            elsif (match_data = a["href"].to_s.match(%r{attachment\.php\?id=(\d+)}))
                attach_id = match_data[1].to_i

                result = @attachment_cache[attach_id]
                if result
                    original_path = File.join(UPLOADS_DIR, result["attach_location"])
                    directory = File.dirname(original_path)
                    filename = result["attach_file"].encode("UTF-8", invalid: :replace, undef: :replace, replace: "")

                    extname = File.extname(result["attach_location"])
                    basename = File.basename(result["attach_location"], extname)

                    new_filename = filename if File.extname(filename).length > 1
                    new_filename ||= "#{filename}#{extname}"
                    new_path = File.join(directory, new_filename)

                    if File.exist?(original_path) && !File.exist?(new_path)
                        File.rename(original_path, new_path)
                    end

                    if File.exist?(new_path)
                        begin
                            upload = create_upload(user_id, new_path, new_filename)
                            if upload&.persisted?
                                new_url = html_for_upload(upload, new_filename)
                                if img
                                    img.replace(new_url)
                                    img.remove_attribute("data-src")
                                    a.remove
                                else
                                    a.replace(new_url)
                                end
                            else
                                error_msg = upload ? upload.errors.full_messages.join(', ') : "Upload object is nil"
                                log_error "\nUpload persisted? false for attach_id #{attach_id} file #{new_filename}: #{error_msg} | #{@current_post_context}"
                                a.replace("[Upload failed: #{new_filename}]")
                            end
                        rescue StandardError => e
                            log_error "\nError processing attachment script link for attach_id #{attach_id} file #{new_filename}: #{e.message} | #{@current_post_context}"
                            a.replace("[Upload failed: #{new_filename}]")
                        end
                    else
                        a.replace("[Missing Attachment: #{new_filename}]")
                    end
                else
                    a.replace("[Missing Attachment ID: #{attach_id}]")
                end
            elsif(a["href"].to_s.start_with?("<fileStore.core_Attachment>/"))
                filename = File.basename(a["href"].to_s).encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
                extracted_path = a["href"].to_s.sub("<fileStore.core_Attachment>/", "")
                path = File.join(UPLOADS_DIR, extracted_path)
                if File.exist?(path)
                    begin
                        upload = create_upload(user_id, path, filename)
                        if upload&.persisted?
                            new_url = html_for_upload(upload, filename)
                            a.replace(new_url)
                        else
                            error_msg = upload ? upload.errors.full_messages.join(', ') : "Upload object is nil"
                            log_error "\nUpload persisted? false for core_Attachment link file #{filename}: #{error_msg} | #{@current_post_context}"
                            a.replace("[Upload failed: #{filename}]")
                        end
                    rescue StandardError => e
                        log_error "\nError processing core_Attachment link file #{filename}: #{e.message} | #{@current_post_context}"
                        a.replace("[Upload failed: #{filename}]")
                    end
                else
                    a.replace("[Missing Attachment: #{filename}]")
                end
            elsif(a["href"].to_s.start_with?("<___base_url___>"))
                # Internal IPS4 link that is NOT an attachment.
                # Strip the placeholder to produce a root-relative URL (e.g. /index.php?showforum=24).
                # Using a relative path instead of Discourse.base_url ensures the links remain
                # correct after the database is moved from dev to production.
                a["href"] = a["href"].sub("<___base_url___>", "")
            elsif(a["href"].to_s.start_with?("<"))
                a.remove
            end
        end

        doc.css("img").each do |img|
            img["src"] = img["data-src"] if img["data-src"]
            img.remove_attribute("data-src")
            if img["src"]&.match(%r{/uploads/imageproxy/([^/]+)$})
                filename = $1
                path = File.join(UPLOADS_DIR, "imageproxy", filename)

                if File.exist?(path)
                    begin
                        upload = create_upload(user_id, path, filename)
                        if upload&.persisted?
                            image_url = html_for_upload(upload, filename)
                            img.replace(image_url)
                        end
                    rescue StandardError => e
                        log_error "\nError processing imageproxy upload file #{filename}: #{e.message} | #{@current_post_context}"
                    end
                end
            elsif img["src"].to_s.start_with?("<fileStore.core_Attachment>/")
                filename = File.basename(img["src"].to_s).encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
                extracted_path = img["src"].to_s.sub("<fileStore.core_Attachment>/", "")
                path = File.join(UPLOADS_DIR, extracted_path)

                if File.exist?(path)
                    begin
                        upload = create_upload(user_id, path, filename)
                        if upload&.persisted?
                            image_url = html_for_upload(upload, filename)
                            img.replace(image_url)
                        else
                            error_msg = upload ? upload.errors.full_messages.join(', ') : "Upload object is nil"
                            log_error "\nUpload persisted? false for image link file #{filename}: #{error_msg} | #{@current_post_context}"
                            img.replace("[Upload failed: #{filename}]")
                        end
                    rescue StandardError => e
                        log_error "\nError processing image link file #{filename}: #{e.message} | #{@current_post_context}"
                        img.replace("[Upload failed: #{filename}]")
                    end
                else
                    img.replace("[Missing Attachment: #{filename}]")
                end
            elsif img["src"].to_s.start_with?("<fileStore.core_Emoticons>/")
                extracted_path = img["src"].to_s.sub("<fileStore.core_Emoticons>/", "")
                filename = File.basename(extracted_path).encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
                
                core_name = filename.downcase.sub(/^default_/, '').sub(/@2x\.png$/, '').sub(/\.(png|gif)$/, '')
                emoji = EMOTICON_MAPPING[core_name] || "🙂"
                img.replace(emoji)
            elsif img["src"]&.match(%r{/uploads/(.+)$})
                extracted_path = $1.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
                filename = File.basename(extracted_path)
                path = File.join(UPLOADS_DIR, extracted_path)
        
                if File.exist?(path)
                    begin
                        upload = create_upload(user_id, path, filename)
                        if upload&.persisted?
                            image_url = html_for_upload(upload, filename)
                            img.replace(image_url)
                        end
                    rescue StandardError => e
                        log_error "\nError processing image upload: #{e.message} | #{@current_post_context}"
                    end
                end
            end
        end

        doc.css("iframe").each do |iframe|
            url = iframe["data-embed-src"] || iframe["src"]
            next unless url
    
            if match = url.match(%r{<___base_url___>/index\.php\?app=core&module=system&controller=embed&url=(.+)$})
                embedded_url = CGI.unescape(CGI.unescapeHTML(CGI.unescape(match[1])))
            elsif url.start_with?("https://www.youtube.com/embed/") or url.start_with?("https://www.youtube-nocookie.com/embed/")
                youtube_id = url.match(%r{/embed/([^?]+)})[1]
                embedded_url = "https://www.youtube.com/watch?v=#{youtube_id}"
            elsif url.match(%r{/topic/(\d+)-.*\?do=embed})
                topic_id = url.match(%r{/topic/(\d+)-.*\?do=embed})[1]
                discourse_topic_id = post_id_from_imported_post_id("t-#{topic_id}")
                if discourse_topic_id
                    embedded_url = "#{Discourse.base_url}/t/topic/#{discourse_topic_id}"
                end
            elsif iframe_allowed?(url)
                # Keep as an actual <iframe> — add https: for protocol-relative URLs.
                # SiteSetting.allowed_iframes is extended in execute to permit these domains.
                clean_src  = url.start_with?("//") ? "https:#{url}" : url
                width      = iframe["width"]&.strip || "100%"
                height     = iframe["height"]&.strip || "300"
                iframe_tag = "<iframe src=\"#{CGI.escapeHTML(clean_src)}\" width=\"#{CGI.escapeHTML(width)}\" height=\"#{CGI.escapeHTML(height)}\" frameborder=\"0\" allowfullscreen=\"allowfullscreen\"></iframe>"
                placeholder = "XIFRX#{@iframe_placeholders.size}X"
                @iframe_placeholders[placeholder] = "\n#{iframe_tag}\n"
                parent = iframe.parent
                if parent&.name == "p" && parent.children.reject { |c| c.text? && c.text.strip.empty? } == [iframe]
                    parent.replace(placeholder)
                else
                    iframe.replace(placeholder)
                end
                next
            elsif url.start_with?("//")
                # Generic protocol-relative external URL — prefix https so Discourse can onebox it
                embedded_url = "https:#{url}"
            elsif url.start_with?("http://") || url.start_with?("https://")
                embedded_url = url
            end
            if embedded_url
                parent = iframe.ancestors.to_a.find { |el| el.parent } || iframe
                formatted_url = "\n#{embedded_url.strip}\n"
                if parent && parent.parent
                    parent.content = formatted_url
                else
                    iframe.content = formatted_url
                end
            else 
                parent = iframe.ancestors.to_a.find { |el| el.parent }
                
                if parent && parent.parent
                    parent.remove
                else
                    iframe.remove
                end
            end
        end

        # Fix IPS4 user mentions
        # IPS4 emits two patterns:
        #   A: <strong>@<a href="...profile/ID-slug...">Name</a></strong>  (@ and link in same strong)
        #   B: <strong>@</strong><strong><a href="...profile/ID-slug...">Name</a></strong>  (two strongs)
        # The profile URL contains the IPS4 member ID: /profile/7758-slug/ → ID 7758
        #
        # Resolution:
        #   - User found → @username  (functional Discourse mention, e.g. @klierik or @user406)
        #   - User not found in DB → [@DisplayName](original-ips4-profile-url)
        doc.css("a[href*='/profile/']").each do |a|
            href = a["href"].to_s
            ips_user_id = href.match(%r{/profile/(\d+)-})&.[](1)

            mention = nil
            if ips_user_id
                discourse_user_id = user_id_from_imported_user_id(ips_user_id)
                username = @mention_username_cache[discourse_user_id] if discourse_user_id
                mention = "@#{username}" if username
            end

            # User not found in DB — preserve link with IPS4 display name
            mention ||= "<a href=\"#{href}\">@#{a.text.strip}</a>"

            parent = a.parent
            next unless parent&.name == "strong"

            prev_strong = parent.previous_element
            if prev_strong&.name == "strong" && prev_strong.text.strip == "@"
                # Pattern B: two separate <strong> nodes
                prev_strong.remove
                parent.replace(mention)
            elsif parent.text.strip.start_with?("@")
                # Pattern A: @ and link inside the same <strong>
                parent.replace(mention)
            end
        end

        markdown = ReverseMarkdown.convert(doc.to_html)

        # Restore quote placeholders with actual [quote] BBCode
        if @quote_placeholders&.any?
            @quote_placeholders.each do |placeholder, bbcode|
                markdown.gsub!(placeholder, bbcode)
            end
            @quote_placeholders.clear
        end

        # Restore iframe placeholders with actual <iframe> HTML
        if @iframe_placeholders&.any?
            @iframe_placeholders.each do |placeholder, html|
                markdown.gsub!(placeholder, html)
            end
            @iframe_placeholders.clear
        end

        markdown
    end

    def mysql_query(sql)
        begin
            results = @client.query(sql)
            results.each do |row|
                row.each do |k, v|
                    if v.is_a?(String)
                        v.force_encoding("UTF-8")
                        v.encode!("UTF-8", invalid: :replace, undef: :replace, replace: "") unless v.valid_encoding?
                    end
                end
            end
            results
        rescue Mysql2::Error => e
            log_error "MySQL Query Error: #{e.message}"
            []
        end
    end
end

ImportScripts::IPBoard4PostUpdater.new.execute
