# frozen_string_literal: true

# IPS4 to Discourse Migration Toolkit
# Copyright (C) 2026 Oleksii Filippovych
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

require "mysql2"
require "reverse_markdown"
require "yaml"
require "tempfile"
require "open-uri"
require "uri"
require File.expand_path(File.dirname(__FILE__) + "/base.rb")

class ImportScripts::IPBoard4Custom < ImportScripts::Base
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

    SiteSetting.disable_emails = "non-staff"
    SiteSetting.disable_digest_emails = true

    def initialize
        super

        @client = Mysql2::Client.new(
            host: ENV["DB_HOST"] || CONFIG.dig("database", "host") || "localhost",
            username: ENV["DB_USER"] || CONFIG.dig("database", "username") || "root",
            password: ENV.has_key?("DB_PW") ? ENV["DB_PW"] : CONFIG.dig("database", "password").to_s,
            database: ENV["DB_NAME"] || CONFIG.dig("database", "name") || "ips4",
            port: CONFIG.dig("database", "port") || 3306
        )

        @client.query("SET NAMES utf8mb4")

        Regexp.timeout = 5

        @attachment_cache       = {}
        @quote_post_cache       = {}
        @mention_username_cache = {}

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
        @started_at   = Time.now
        @import_stats = {}

        puts "Starting Advanced IPBoard4 to Discourse Migration..."
        puts "Using config from: #{CONFIG_PATH}"

        @options = {
            duplicate_email_handling: CONFIG.dig("advanced_options", "duplicate_email_handling")&.to_sym || :dummy_email,
            invalid_email_handling: CONFIG.dig("advanced_options", "invalid_email_handling")&.to_sym || :dummy_email,
            duplicate_username_handling: CONFIG.dig("advanced_options", "duplicate_username_handling")&.to_sym || :append_id,
            invalid_username_handling: CONFIG.dig("advanced_options", "invalid_username_handling")&.to_sym || :sanitize_and_append_id,
            orphaned_topic_handling: CONFIG.dig("advanced_options", "orphaned_topic_handling")&.to_sym || :assign_system,
            orphaned_post_handling: CONFIG.dig("advanced_options", "orphaned_post_handling")&.to_sym || :assign_system,
        }
        puts "Configuration options loaded: #{@options.inspect}"

        # Temporarily relax strict Discourse validations during import
        current_extensions = SiteSetting.authorized_extensions.to_s
        new_extensions = CONFIG.dig("import", "allowed_extensions") || ["zip", "rar", "7z", "tar", "gz"]
        combined_extensions = (current_extensions.split("|") + new_extensions).uniq.join("|")
        SiteSetting.authorized_extensions = combined_extensions

        SiteSetting.max_attachment_size_kb = CONFIG.dig("import", "max_attachment_size_kb") || 262144 # Default to 256MB if not in config

        # Permit iframes from known embed providers so <iframe> tags survive post cooking
        current_iframes         = SiteSetting.allowed_iframes.to_s
        @allowed_iframe_domains = CONFIG.dig("import", "allowed_iframe_domains") || ["https://jsfiddle.net/", "https://codepen.io/"]
        combined_iframes        = (current_iframes.split("|") + @allowed_iframe_domains).uniq.join("|")
        SiteSetting.allowed_iframes = combined_iframes
        puts "Allowed iframes set to: #{SiteSetting.allowed_iframes}"

        SiteSetting.unicode_usernames = true
        SiteSetting.min_username_length = 2
        SiteSetting.max_username_length = 60
        SiteSetting.allow_uppercase_posts = true
        SiteSetting.max_post_length = 150000

        import_users            if CONFIG.dig("import", "run_users")            != false
        import_categories       if CONFIG.dig("import", "run_categories")       != false
        import_topics           if CONFIG.dig("import", "run_topics")           != false
        import_posts            if CONFIG.dig("import", "run_posts")            != false
        import_likes            if CONFIG.dig("import", "run_likes")            != false
        import_tags             if CONFIG.dig("import", "run_tags")             != false
        import_articles         if CONFIG.dig("import", "run_articles")         != false
        import_private_messages if CONFIG.dig("import", "run_private_messages") != false
        create_seo_perma_links  if CONFIG.dig("import", "run_seo_permalinks")   != false
        wipe_post_revisions     if WIPE_REVISIONS

        elapsed = (Time.now - @started_at).to_i
        h, rem  = elapsed.divmod(3600)
        m, s    = rem.divmod(60)

        puts ""
        puts "=" * 80
        puts "  Import Complete — Summary"
        puts "-" * 80
        puts format("  %-28s %s", "Elapsed time:", format("%02d:%02d:%02d", h, m, s))
        puts "-" * 80
        puts format("  %-28s %10s", "Step", "Source rows")
        puts "-" * 80
        {
            "Users"            => @import_stats[:users],
            "Categories"       => @import_stats[:categories],
            "Topics"           => @import_stats[:topics],
            "Posts"            => @import_stats[:posts],
            "Articles"         => @import_stats[:articles],
            "Private messages" => @import_stats[:message_topics],
            "PM posts"         => @import_stats[:message_posts],
        }.each do |label, count|
            status = count ? format("%10d", count) : "   skipped"
            puts format("  %-28s %s", label, status)
        end
        puts format("  %-28s %10d added, %d skipped, %d collisions",
            "SEO permalinks",
            @seo_added    || 0,
            @seo_skipped  || 0,
            @seo_collisions || 0
        )
        puts "=" * 80
        puts "  Run the following rake tasks to rebuild derived data:"
        puts "    RAILS_ENV=production bundle exec rake posts:rebake"
        puts "    RAILS_ENV=production bundle exec rake topics:fix_counts"
        puts "=" * 80
    end

    def fetch_forum_moderators
        forum_moderators = mysql_query(<<~SQL)
            SELECT DISTINCT m.member_id
            FROM #{TABLE_PREFIX}core_members m
            LEFT JOIN #{TABLE_PREFIX}core_moderators modee ON m.member_id = modee.id
            WHERE modee.type = 'm';
        SQL

        forum_moderators.map { |row| row["member_id"].to_i }
    end

    def fetch_admins
        admin_rows = mysql_query(<<~SQL).to_a
            SELECT row_id, row_id_type FROM #{TABLE_PREFIX}core_admin_permission_rows;
        SQL

        group_admin_ids = []
        member_admin_ids = []

        admin_rows.each do |row|
            if row["row_id_type"] == "group"
                group_admin_ids << row["row_id"].to_i
            elsif row["row_id_type"] == "member"
                member_admin_ids << row["row_id"].to_i
            end
        end

        group_admin_users = mysql_query(<<~SQL)
            SELECT DISTINCT member_id FROM #{TABLE_PREFIX}core_members WHERE member_group_id IN (#{group_admin_ids.join(",")});
        SQL

        (group_admin_users.map { |row| row["member_id"].to_i } + member_admin_ids).uniq
    end

    def import_users
        puts "", "importing users..."

        last_user_id = -1
        
        # Check if field_11 exists in core_pfields_content
        about_me_column = nil
        mysql_query("SHOW COLUMNS FROM #{TABLE_PREFIX}core_pfields_content").each do |r|
            about_me_column = "field_11" if r["Field"] == "field_11"
        end

        # Check which optional columns exist in core_members (schema differs across IPS4 versions)
        optional_cols = {}
        mysql_query("SHOW COLUMNS FROM #{TABLE_PREFIX}core_members").each do |r|
            case r["Field"]
            when "pp_photo_url"    then optional_cols[:pp_photo_url]    = true
            when "member_location" then optional_cols[:member_location] = true
            when "pp_website"      then optional_cols[:pp_website]      = true
            when "timezone"        then optional_cols[:timezone]        = true
            end
        end
        has_photo_url = optional_cols[:pp_photo_url]
        has_location  = optional_cols[:member_location]
        has_website   = optional_cols[:pp_website]
        has_timezone  = optional_cols[:timezone]
        
        total_users = mysql_query("SELECT COUNT(*) count FROM #{TABLE_PREFIX}core_members").first["count"]
        @import_stats[:users] = total_users
        moderator_ids = fetch_forum_moderators
        admin_ids = fetch_admins

        batches(BATCH_SIZE) do |offset|
            about_me_sql = about_me_column ? "NULLIF(p.#{about_me_column}, '')" : "NULL"
            
            users = mysql_query(<<~SQL).to_a
                SELECT m.member_id AS id,
                    m.name,
                    m.email,
                    m.joined,
                    m.ip_address,
                    m.member_title AS title,
                    CASE 
                        WHEN m.bday_year IS NULL OR m.bday_year = 0 
                            OR m.bday_month IS NULL OR m.bday_month = 0 
                            OR m.bday_day IS NULL OR m.bday_day = 0 
                        THEN NULL 
                        ELSE CONCAT(m.bday_year, '-', LPAD(m.bday_month, 2, '0'), '-', LPAD(m.bday_day, 2, '0')) 
                    END AS date_of_birth,
                    m.last_activity,
                    m.temp_ban AS member_banned,
                    m.member_group_id,
                    #{about_me_sql} AS pp_about_me,
                    m.pp_main_photo#{has_photo_url ? ", m.pp_photo_url" : ""}#{has_location ? ", NULLIF(TRIM(m.member_location), '') AS member_location" : ""}#{has_website ? ", NULLIF(TRIM(m.pp_website), '') AS pp_website" : ""}#{has_timezone ? ", NULLIF(TRIM(m.timezone), '') AS timezone" : ""}
                FROM #{TABLE_PREFIX}core_members AS m
                LEFT JOIN #{TABLE_PREFIX}core_pfields_content AS p ON m.member_id = p.member_id
                WHERE m.member_id > #{last_user_id}
                ORDER BY m.member_id
                LIMIT #{BATCH_SIZE}
            SQL

            break if users.empty?

            last_user_id = users.last["id"] || last_user_id if users.any?

            create_users(users, total: total_users, offset: offset) do |u|
                next if user_id_from_imported_user_id(u["id"])

                # Force UTF-8 encoding for all fields to avoid ASCII-8BIT errors in Discourse validators
                u.each do |k, v|
                    if v.is_a?(String)
                        v.force_encoding("UTF-8")
                        v.encode!("UTF-8", invalid: :replace, undef: :replace, replace: "") unless v.valid_encoding?
                    end
                end

                username = u["name"].to_s.strip
                
                # Sanitize username: keep alphanumeric, underscore, and dash
                username = username.gsub(/[^a-zA-Z0-9_\-]/, '')
                username = "user_#{u["id"]}" if username.blank? || username.length < 2

                email = u["email"].to_s.strip
                
                # Discourse strictly rejects Gmail addresses with excessive dots.
                # If Email.is_valid? fails (which applies the strict Discourse rules), 
                # we keep the original email but bypass the initial check to see if the database accepts it.
                # If the email is fundamentally broken (e.g. empty or no @ sign), use a dummy.
                if email.blank? || !email.include?("@")
                    email = "imported_user_#{u["id"]}@example.invalid"
                end

                title = u["title"].to_s.strip
                bio = u["pp_about_me"].to_s.strip

                is_moderator = moderator_ids.include?(u["id"].to_i)
                is_admin = admin_ids.include?(u["id"].to_i)

                date_of_birth =
                begin
                    Date.parse(u["date_of_birth"]) if u["date_of_birth"].present?
                rescue ArgumentError
                    nil
                end

                user_hash = {
                    id: u["id"],
                    username: username,
                    email: email,
                    created_at: Time.zone.at(u["joined"]),
                    registration_ip_address: u["ip_address"],
                    title: CGI.unescapeHTML(title.presence || ""),
                    date_of_birth: date_of_birth,
                    last_seen_at: Time.zone.at(u["last_activity"]),
                    admin: is_admin,
                    moderator: is_moderator,
                    bio_raw: clean_up(bio),
                    post_create_action:
                        proc do |new_user|
                            if u["member_banned"] == 1
                                new_user.update(suspended_at: DateTime.now, suspended_till: 100.years.from_now)
                            else
                                # Determine avatar source: local file or remote URL
                                # IPS4 can store URLs directly in pp_main_photo (Google/social login)
                                avatar_uploaded = false
                                photo_path = u["pp_main_photo"].to_s
                                photo_url  = has_photo_url ? u["pp_photo_url"].to_s : ""

                                # 1. If pp_main_photo is a URL (starts with http) → download from remote
                                if photo_path.present? && photo_path.start_with?("http")
                                    begin
                                        url = photo_path
                                        uri = URI.parse(url)
                                        filename = File.basename(uri.path).presence || "avatar_#{u["id"]}.jpg"
                                        filename += ".jpg" unless filename.include?(".")

                                        Tempfile.create(["ips4_avatar_#{u["id"]}_", File.extname(filename)], binmode: true) do |tmp|
                                            URI.open(url, "User-Agent" => "Mozilla/5.0", read_timeout: 15, open_timeout: 10) do |stream|
                                                bytes_read = 0
                                                while (chunk = stream.read(64 * 1024))
                                                    bytes_read += chunk.bytesize
                                                    break if bytes_read > 5 * 1024 * 1024 # 5MB limit
                                                    tmp.write(chunk)
                                                end
                                            end
                                            tmp.flush
                                            tmp.rewind

                                            upload = create_upload(new_user.id, tmp.path, filename)
                                            if upload&.persisted?
                                                new_user.create_user_avatar unless new_user.user_avatar
                                                new_user.user_avatar.update(custom_upload_id: upload.id)
                                                new_user.update(uploaded_avatar_id: upload.id)
                                                puts "Updated REMOTE avatar for #{username} (#{u["id"]}): #{url}"
                                                avatar_uploaded = true
                                            else
                                                error_msg = upload ? upload.errors.full_messages.join(", ") : "Upload is nil"
                                                puts "\nFailed to upload remote avatar for user #{u["id"]}: #{error_msg}"
                                            end
                                        end
                                    rescue StandardError => e
                                        puts "\nFailed to download remote avatar for user #{u["id"]}: #{e.message}"
                                    end
                                end

                                # 2. If pp_main_photo is a local file path → upload from disk
                                if !avatar_uploaded && photo_path.present?
                                    path = File.join(UPLOADS_DIR, photo_path)
                                    if File.exist?(path)
                                        begin
                                            upload = create_upload(new_user.id, path, File.basename(path))
                                            if upload&.persisted?
                                                new_user.create_user_avatar unless new_user.user_avatar
                                                new_user.user_avatar.update(custom_upload_id: upload.id)
                                                new_user.update(uploaded_avatar_id: upload.id)
                                                puts "Updated LOCAL avatar for #{username} (#{u["id"]}): #{photo_path}"
                                                avatar_uploaded = true
                                            end
                                        rescue StandardError => e
                                            puts "\nFailed to upload local avatar for user #{u["id"]}: #{e.message}"
                                        end
                                    end
                                end

                                # 3. Fall back to external URL avatar (Google, social, etc.) if column exists
                                if !avatar_uploaded && photo_url.present? && photo_url.start_with?("http")
                                    begin
                                        url = photo_url
                                        uri = URI.parse(url)
                                        filename = File.basename(uri.path).presence || "avatar_#{u["id"]}.jpg"
                                        filename += ".jpg" unless filename.include?(".")

                                        Tempfile.create(["ips4_avatar_#{u["id"]}_", File.extname(filename)], binmode: true) do |tmp|
                                            URI.open(url, "User-Agent" => "Mozilla/5.0", read_timeout: 15, open_timeout: 10) do |stream|
                                                bytes_read = 0
                                                while (chunk = stream.read(64 * 1024))
                                                    bytes_read += chunk.bytesize
                                                    break if bytes_read > 5 * 1024 * 1024 # 5MB limit
                                                    tmp.write(chunk)
                                                end
                                            end
                                            tmp.flush
                                            tmp.rewind

                                            upload = create_upload(new_user.id, tmp.path, filename)
                                            if upload&.persisted?
                                                new_user.create_user_avatar unless new_user.user_avatar
                                                new_user.user_avatar.update(custom_upload_id: upload.id)
                                                new_user.update(uploaded_avatar_id: upload.id)
                                                puts "Updated REMOTE avatar (fallback) for #{username} (#{u["id"]}): #{url}"
                                            else
                                                error_msg = upload ? upload.errors.full_messages.join(", ") : "Upload is nil"
                                                puts "\nFailed to upload remote avatar (fallback) for user #{u["id"]}: #{error_msg}"
                                            end
                                        end
                                    rescue StandardError => e
                                        puts "\nFailed to download remote avatar (fallback) for user #{u["id"]}: #{e.message}"
                                    end
                                end
                            end

                            # Set UserProfile fields (location, website) — set regardless of ban status
                            profile_attrs = {}
                            profile_attrs[:location] = u["member_location"].to_s.strip if has_location && u["member_location"].present?
                            profile_attrs[:website]  = u["pp_website"].to_s.strip       if has_website  && u["pp_website"].present?
                            new_user.user_profile.update(profile_attrs) rescue nil if profile_attrs.any?

                            # Set timezone
                            if has_timezone && u["timezone"].present?
                                new_user.user_option.update(timezone: u["timezone"].to_s.strip) rescue nil
                            end
                        end,
                }
                
                temp_user = User.new(user_hash.except(:id, :post_create_action, :bio_raw))
                unless temp_user.valid?
                    # Handle duplicate or blocked emails
                    email_errors = temp_user.errors.full_messages.join(" ")
                    if email_errors.include?("taken")
                        if @options[:duplicate_email_handling] == :dummy_email
                            domain = email.split('@').last || "example.invalid"
                            puts "Email #{email} already taken for user #{username} (#{u["id"]}). Using fallback email."
                            user_hash[:email] = "imported_duplicate_#{u["id"]}@#{domain}"
                        else
                            puts "Skipping user #{u["id"]} due to duplicate email."
                            next
                        end
                    elsif email_errors.include?("provider") || email_errors.include?("not allowed")
                        if @options[:invalid_email_handling] == :dummy_email
                            puts "Email #{email} from blocked provider for user #{username} (#{u["id"]}). Using fallback email."
                            user_hash[:email] = "imported_fallback_#{u["id"]}@example.invalid"
                        else
                            puts "Skipping user #{u["id"]} due to blocked email provider."
                            next
                        end
                    end
                    
                    # Handle duplicate or invalid usernames
                    if temp_user.errors.messages[:username]&.any?
                        if @options[:duplicate_username_handling] == :append_id || @options[:invalid_username_handling] == :sanitize_and_append_id
                            original_username = username
                            username = "#{username}_#{u["id"]}"
                            if @options[:invalid_username_handling] == :sanitize_and_append_id
                                username = username.gsub(/[^a-zA-Z0-9_\-]/, '') # Ensure strict alphanumeric
                            end
                            username = "user_#{u["id"]}" if username.blank? || username.length < 2
                            user_hash[:username] = username
                            puts "Username '#{original_username}' taken or invalid. Using '#{username}' instead."
                        else
                            puts "Skipping user #{u["id"]} due to duplicate or invalid username."
                            next
                        end
                    end

                    # Generic fallback if still invalid after fixes
                    final_check = User.new(user_hash.except(:id, :post_create_action, :bio_raw))
                    unless final_check.valid?
                        puts "Pre-validation failed for #{username} / #{email}: #{final_check.errors.full_messages.join(', ')}. Skipping."
                        next
                    end
                end
                
                user_hash
            end
        end
    end

    def import_categories
        puts "", "importing categories..."
        categories = mysql_query(<<~SQL).to_a
            SELECT 
                f.id AS id,
                CASE 
                    WHEN p.parent_id = -1 THEN -1
                    ELSE f.parent_id
                END AS parent_id,
                f.position AS position,
                parent_lang.word_default AS category_name,
                desc_lang.word_default AS description
            FROM #{TABLE_PREFIX}forums_forums f
            JOIN #{TABLE_PREFIX}core_sys_lang_words parent_lang 
                ON parent_lang.word_key = CONCAT('forums_forum_', f.id)
            JOIN #{TABLE_PREFIX}core_sys_lang_words desc_lang 
                ON desc_lang.word_key = CONCAT('forums_forum_', f.id, '_desc')
            LEFT JOIN #{TABLE_PREFIX}forums_forums p
                ON f.parent_id = p.id
            WHERE f.parent_id != -1
        SQL

        parent_categories = categories.select { |c| c["parent_id"] == -1 }
        child_categories = categories.select { |c| c["parent_id"] != -1 }
    
        create_categories(parent_categories) do |c|
        next if category_id_from_imported_category_id(c["id"])
        {
            id: c["id"],
            name: c["category_name"].encode("utf-8", "utf-8"),
            description: clean_up(c["description"]),
            position: c["position"],
        }
        end
    
        create_categories(child_categories) do |c|
        next if category_id_from_imported_category_id(c["id"])
        {
            id: c["id"],
            parent_category_id: category_id_from_imported_category_id(c["parent_id"]),
            name: c["category_name"].encode("utf-8", "utf-8"),
            description: clean_up(c["description"]),
            position: c["position"],
        }
        end
    end

    def import_topics
        puts "", "importing topics..."
    
        last_topic_id = -1
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

        puts "Total topics to be imported: #{total_topics}"
        @import_stats[:topics] = total_topics

        batches(BATCH_SIZE) do |offset|
            topics = mysql_query(<<~SQL).to_a
                SELECT t.tid AS id, t.title, t.state, t.starter_id, t.start_date, t.views, t.forum_id, t.pinned, p.post
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

            @attachment_cache       = build_attachment_cache(topics.map { |r| r["post"] })
            @quote_post_cache       = build_quote_post_cache(topics.map { |r| r["post"] })
            @mention_username_cache = build_mention_username_cache(topics.map { |r| r["post"] })
            @topic_link_cache       = build_topic_link_cache(topics.map { |r| r["post"] })

            create_posts(topics, total: total_topics, offset: offset) do |t|
                next if post_id_from_imported_post_id("t-#{t["id"]}")

                created_at = Time.zone.at(t["start_date"])
                user_id = user_id_from_imported_user_id(t["starter_id"])
                if user_id.nil?
                    if @options[:orphaned_topic_handling] == :assign_system
                        user_id = Discourse.system_user.id
                    else
                        puts "Skipping orphaned topic t-#{t["id"]} (User ID #{t["starter_id"]} not found)"
                        next
                    end
                end
                @current_post_context = "IPS4 topic t-#{t["id"]}"
                {
                    id: "t-#{t["id"]}",
                    title: CGI.unescapeHTML(t["title"].encode("utf-8", "utf-8")),
                    user_id: user_id,
                    created_at: created_at,
                    views: t["views"],
                    category: category_id_from_imported_category_id(t["forum_id"]),
                    pinned_at: t["pinned"] == 1 ? created_at : nil,
                    raw: clean_up(t["post"], user_id),
                    closed: t["state"] != "open"
                }
            end
        end
    end

    def import_posts
        puts "", "importing posts..."
    
        last_post_id = -1
        total_posts = mysql_query(<<~SQL).first["count"]
            SELECT COUNT(*) AS count
            FROM #{TABLE_PREFIX}forums_posts
            WHERE new_topic = 0
                AND pdelete_time = 0
                AND queued = 0
        SQL

        puts "Total posts to be imported: #{total_posts}"
        @import_stats[:posts] = total_posts
    
        batches(BATCH_SIZE) do |offset|
            posts = mysql_query(<<~SQL).to_a
                SELECT pid AS id, author_id, post_date, post, topic_id
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

            @attachment_cache       = build_attachment_cache(posts.map { |r| r["post"] })
            @quote_post_cache       = build_quote_post_cache(posts.map { |r| r["post"] })
            @mention_username_cache = build_mention_username_cache(posts.map { |r| r["post"] })
            @topic_link_cache       = build_topic_link_cache(posts.map { |r| r["post"] })

            create_posts(posts, total: total_posts, offset: offset) do |p|
                next if post_id_from_imported_post_id(p["id"])

                topic = topic_lookup_from_imported_post_id("t-#{p["topic_id"]}")
                if topic.nil?
                    puts "Skipping post #{p["id"]} - Topic ID #{p["topic_id"]} not found"
                    next
                end

                user_id = user_id_from_imported_user_id(p["author_id"])
                if user_id.nil?
                    if @options[:orphaned_post_handling] == :assign_system
                        user_id = Discourse.system_user.id
                    else
                        puts "Skipping orphaned post #{p["id"]} (User ID #{p["author_id"]} not found)"
                        next
                    end
                end

                @current_post_context = "IPS4 post #{p["id"]} in topic t-#{p["topic_id"]}"
                {
                    id: p["id"],
                    user_id: user_id,
                    created_at: Time.zone.at(p["post_date"]),
                    raw: clean_up(p["post"], user_id),
                    topic_id: topic[:topic_id],
                }
            end
        end
    end

    def import_likes
        puts "", "importing post likes"
    
        last_id = -1
        RateLimiter.disable

        batches(BATCH_SIZE) do |offset|
            likes = mysql_query(<<-SQL).to_a
                SELECT id, member_id AS user_id, type_id AS post_id, rep_date AS created_at
                FROM #{TABLE_PREFIX}core_reputation_index
                WHERE rep_rating = 1
                AND id > #{last_id}
                ORDER BY id
                LIMIT #{BATCH_SIZE}
            SQL

            break if likes.empty?

            last_id = likes[-1]["id"]
        
            likes.each do |like|
                user_id = user_id_from_imported_user_id(like["user_id"])
                next unless user_id

                post_id = post_id_from_imported_post_id(like["post_id"])
                next unless post_id

                user = User.find_by(id: user_id)
                next unless user

                post = Post.find_by(id: post_id)
                next unless post

                next if PostAction.exists?(user_id: user_id, post_id: post_id, post_action_type_id: 2)

                begin
                    PostActionCreator.like(user,post)

                rescue StandardError => e
                    puts "Error importing like for post #{like["post_id"]} by user #{like["user_id"]}: #{e.message}"
                end
            end
        end
        RateLimiter.enable
    end

    def import_tags
        puts "", "importing tags..."
        
        SiteSetting.tagging_enabled = true
        SiteSetting.max_tags_per_topic = 100

        last_topic_id = -1

        batches(BATCH_SIZE) do |offset|
            tags = mysql_query(<<~SQL).to_a
                SELECT 
                    t.tag_meta_id AS topic_id, 
                    GROUP_CONCAT(LOWER(TRIM(t.tag_text)) ORDER BY t.tag_id SEPARATOR ', ') AS tags
                FROM #{TABLE_PREFIX}core_tags t
                LEFT JOIN #{TABLE_PREFIX}forums_topics ft ON t.tag_meta_id = ft.tid
                WHERE t.tag_meta_app = 'forums'
                AND tid > #{last_topic_id}
                GROUP BY t.tag_meta_id
                ORDER BY topic_id
                LIMIT #{BATCH_SIZE}
            SQL

            break if tags.empty?

            last_topic_id = tags[-1]["topic_id"]
        
            tags.each do |tag|
                topic = topic_lookup_from_imported_post_id("t-#{tag["topic_id"]}")

                if topic.is_a?(Hash) && topic[:topic_id]
                    topic = Topic.find_by(id: topic[:topic_id])
                end

                if topic.is_a?(Topic)

                    tag_names = tag["tags"].encode("utf-8", "utf-8", invalid: :replace, undef: :replace, replace: "")
                                    .split(",").map(&:strip).reject(&:empty?)
                
                    if tag_names.any?
                        DiscourseTagging.tag_topic_by_names(topic, staff_guardian, tag_names)
                    end
                end
            end
        end
    end

    def import_articles
        puts "", "importing articles..."
    
        # Check if the table exists first
        tables = mysql_query("SHOW TABLES LIKE '#{TABLE_PREFIX}cms_custom_database_1'").to_a
        if tables.empty?
            puts "Skipping articles: #{TABLE_PREFIX}cms_custom_database_1 table not found"
            return
        end

        last_article_id = -1
        total_articles = mysql_query(<<~SQL).first["count"]
            SELECT COUNT(*) AS count
            FROM #{TABLE_PREFIX}cms_custom_database_1
            WHERE record_locked = 0
        SQL

        puts "Total articles to be imported: #{total_articles}"
        @import_stats[:articles] = total_articles
        articles_category_id = Category.find_by(name: "articles")&.id

        puts "First create a category named articles" if articles_category_id.nil?
        return if articles_category_id.nil?


        batches(BATCH_SIZE) do |offset|
            articles = mysql_query(<<~SQL).to_a
                SELECT primary_id_field AS id, field_1 AS title, member_id, record_publish_date, record_views AS views,
                CONCAT(field_2, '<br><br><hr><br><br>', field_3) AS post
                FROM #{TABLE_PREFIX}cms_custom_database_1
                WHERE record_locked = 0
                AND primary_id_field > #{last_article_id}
                ORDER BY primary_id_field
                LIMIT #{BATCH_SIZE}
            SQL

            break if articles.empty?

            last_article_id = articles[-1]["id"]

            @attachment_cache       = build_attachment_cache(articles.map { |r| r["post"] })
            @quote_post_cache       = build_quote_post_cache(articles.map { |r| r["post"] })
            @mention_username_cache = build_mention_username_cache(articles.map { |r| r["post"] })
            @topic_link_cache       = build_topic_link_cache(articles.map { |r| r["post"] })

            create_posts(articles, total: total_articles, offset: offset) do |t|
                next if post_id_from_imported_post_id("a-#{t["id"]}")

                created_at = Time.zone.at(t["record_publish_date"])
                user_id = user_id_from_imported_user_id(t["member_id"]) || Discourse.system_user.id

                @current_post_context = "IPS4 article a-#{t["id"]}"
                {
                    id: "a-#{t["id"]}",
                    title: CGI.unescapeHTML(t["title"].encode("utf-8", "utf-8")),
                    user_id: user_id,
                    created_at: created_at,
                    views: t["views"],
                    category: articles_category_id,
                    raw: clean_up(t["post"], user_id)
                }
            end
        end
    end

    def import_private_messages
        puts "", "importing private messages..."

        last_message_topic_id = -1
        total_message_topics = mysql_query("SELECT COUNT(*) count FROM #{TABLE_PREFIX}core_message_topics").first["count"]
        @import_stats[:message_topics] = total_message_topics

        batches(BATCH_SIZE) do |offset|
            message_topics = mysql_query(<<~SQL).to_a
                SELECT mt.mt_id AS id, mt.mt_title AS title, mt.mt_starter_id AS starter_id, mt.mt_date AS created_at
                FROM #{TABLE_PREFIX}core_message_topics mt
                WHERE mt.mt_id > #{last_message_topic_id}
                ORDER BY mt.mt_id
                LIMIT #{BATCH_SIZE}
            SQL

            break if message_topics.empty?

            last_message_topic_id = message_topics.last["id"]

            create_posts(message_topics, total: total_message_topics, offset: offset) do |mt|
                user_id = user_id_from_imported_user_id(mt["starter_id"]) || Discourse.system_user.id
                starter_user = User.find_by(id: user_id)

                target_usernames = fetch_message_participants(mt["id"]).split(",")
                targets = target_usernames.reject { |u| u.blank? || (starter_user && u.downcase == starter_user.username.downcase) }

                if targets.empty?
                    puts "Skipping PM topic mt-#{mt["id"]} - No valid recipients found"
                    next
                end

                {
                    id: "mt-#{mt["id"]}",
                    title: mt["title"],
                    user_id: user_id,
                    created_at: Time.zone.at(mt["created_at"]),
                    archetype: Archetype.private_message,
                    target_usernames: targets.join(","),
                    custom_fields: { import_id: "mt-#{mt["id"]}" }
                }
            end
        end

        import_message_posts
    end

    def fetch_message_participants(mt_id)
        participants = mysql_query(<<~SQL).to_a
            SELECT map_user_id
            FROM #{TABLE_PREFIX}core_message_topic_user_map
            WHERE map_topic_id = #{mt_id}
        SQL
        
        usernames = []
        participants.each do |p|
            user_id = user_id_from_imported_user_id(p["map_user_id"])
            if user_id
                user = User.find_by(id: user_id)
                usernames << user.username if user
            end
        end
        
        usernames.join(",")
    end

    def import_message_posts
        puts "", "importing private message posts..."
        last_msg_id = -1
        @import_stats[:message_posts] = mysql_query("SELECT COUNT(*) count FROM #{TABLE_PREFIX}core_message_posts").first["count"]

        batches(BATCH_SIZE) do |offset|
            msg_posts = mysql_query(<<~SQL).to_a
                SELECT msg_id AS id, msg_author_id AS author_id, msg_date AS date, msg_post AS post, msg_topic_id AS topic_id
                FROM #{TABLE_PREFIX}core_message_posts
                WHERE msg_id > #{last_msg_id}
                ORDER BY msg_id
                LIMIT #{BATCH_SIZE}
            SQL

            break if msg_posts.empty?
            last_msg_id = msg_posts.last["id"]

            @attachment_cache       = build_attachment_cache(msg_posts.map { |r| r["post"] })
            @quote_post_cache       = build_quote_post_cache(msg_posts.map { |r| r["post"] })
            @mention_username_cache = build_mention_username_cache(msg_posts.map { |r| r["post"] })
            @topic_link_cache       = build_topic_link_cache(msg_posts.map { |r| r["post"] })

            create_posts(msg_posts) do |mp|
                topic = topic_lookup_from_imported_post_id("mt-#{mp["topic_id"]}")
                next if topic.nil?

                user_id = user_id_from_imported_user_id(mp["author_id"]) || Discourse.system_user.id

                @current_post_context = "IPS4 PM post mp-#{mp["id"]}"
                {
                    id: "mp-#{mp["id"]}",
                    topic_id: topic[:topic_id],
                    user_id: user_id,
                    created_at: Time.zone.at(mp["date"]),
                    raw: clean_up(mp["post"], user_id)
                }
            end
        end
    end

    def create_seo_perma_links
        puts "", "creating SEO permalinks..."

        @seo_added      = 0
        @seo_skipped    = 0
        @seo_collisions = 0

        # --- Topics ---
        mysql_query("SELECT tid, title_seo FROM #{TABLE_PREFIX}forums_topics ORDER BY tid ASC").each do |row|
            tid       = row["tid"]
            title_seo = row["title_seo"].to_s.strip

            topic_id = topic_lookup_from_imported_post_id("t-#{tid}")&.dig(:topic_id)
            unless topic_id
                @seo_skipped += 1
                next
            end

            # Legacy query-string URL — primary source of 404s for old bookmarks / Google.
            # Discourse matches incoming requests as "path?querystring" (no leading slash).
            add_seo_permalink("index.php?showtopic=#{tid}", topic_id: topic_id)

            # IPS4 pretty-URL variants (both trailing-slash and no-slash forms).
            # Guard against blank title_seo — a nil slug produces malformed "topic/47375-"
            # records that will never match any real request.
            unless title_seo.empty?
                add_seo_permalink("topic/#{tid}-#{title_seo}/", topic_id: topic_id)
                add_seo_permalink("topic/#{tid}-#{title_seo}",  topic_id: topic_id)
            end
        end

        # --- Categories / Forums ---
        mysql_query("SELECT id, name_seo FROM #{TABLE_PREFIX}forums_forums ORDER BY id ASC").each do |row|
            forum_id = row["id"]
            name_seo = row["name_seo"].to_s.strip

            category_id = category_id_from_imported_category_id(forum_id)
            unless category_id
                @seo_skipped += 1
                next
            end

            # Legacy query-string URL
            add_seo_permalink("index.php?showforum=#{forum_id}", category_id: category_id)

            unless name_seo.empty?
                add_seo_permalink("forum/#{forum_id}-#{name_seo}/", category_id: category_id)
                add_seo_permalink("forum/#{forum_id}-#{name_seo}",  category_id: category_id)
            end
        end

        puts "  SEO permalinks — added: #{@seo_added}, skipped (no mapping): #{@seo_skipped}, collisions: #{@seo_collisions}"
    end

    # Creates a single Permalink record if one does not already exist.
    # Uses create! so Discourse's URL normalisation callbacks run.
    # URL collisions caused by normalisation of special characters (e.g. em-dashes
    # mapping two different slugs to the same stored value) are silently counted —
    # the existing record already covers the redirect.
    def add_seo_permalink(url, topic_id: nil, category_id: nil)
        return if Permalink.exists?(url: url)

        attrs = { url: url }
        attrs[:topic_id]    = topic_id    if topic_id
        attrs[:category_id] = category_id if category_id

        begin
            Permalink.create!(attrs)
            @seo_added += 1
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
            @seo_collisions += 1
        end
    end

    def staff_guardian
        @_staff_guardian ||= Guardian.new(Discourse.system_user)
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
            puts "Regex Timeout Error while processing text: #{raw[0..100]}..."
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
        doc.css("pre, code, .ipsCode").each do |code_block|
            code_block.inner_html = code_block.inner_html.gsub(/<br\s*\/?>/i, "\n")
            # We can also wrap it properly or let ReverseMarkdown handle it
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
                                    puts "\nUpload persisted? false for attach_id #{attach_id} file #{new_filename}: #{error_msg} | #{@current_post_context}"
                                    a.replace("[Upload failed: #{new_filename}]")
                                end
                            rescue StandardError => e
                                puts "\nError processing attachment link for attach_id #{attach_id} file #{new_filename}: #{e.message} | #{@current_post_context}"
                                a.replace("[Upload failed: #{new_filename}]")
                            end
                        else
                            a.replace("[Missing Attachment: #{new_filename}]")
                        end
                    else
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
                                puts "\nUpload persisted? false for attach_id #{attach_id} file #{new_filename}: #{error_msg} | #{@current_post_context}"
                                a.replace("[Upload failed: #{new_filename}]")
                            end
                        rescue StandardError => e
                            puts "\nError processing attachment script link for attach_id #{attach_id} file #{new_filename}: #{e.message} | #{@current_post_context}"
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
                            puts "\nUpload persisted? false for core_Attachment link file #{filename}: #{error_msg} | #{@current_post_context}"
                            a.replace("[Upload failed: #{filename}]")
                        end
                    rescue StandardError => e
                        puts "\nError processing core_Attachment link file #{filename}: #{e.message} | #{@current_post_context}"
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
                        puts "\nError processing imageproxy upload file #{filename}: #{e.message} | #{@current_post_context}"
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
                            puts "\nUpload persisted? false for image link file #{filename}: #{error_msg} | #{@current_post_context}"
                            img.replace("[Upload failed: #{filename}]")
                        end
                    rescue StandardError => e
                        puts "\nError processing image link file #{filename}: #{e.message} | #{@current_post_context}"
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
                        puts "\nError processing image upload file #{filename}: #{e.message} | #{@current_post_context}"
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

    # Delete all PostRevision records for imported posts and reset version counters to 1.
    # Runs as a single bulk operation after all import phases complete.
    def wipe_post_revisions
        puts "", "Wiping post revision history for imported posts..."

        imported_post_ids = PostCustomField.where(name: "import_id").pluck(:post_id)

        if imported_post_ids.empty?
            puts "  No imported posts found — nothing to wipe."
            return
        end

        deleted = PostRevision.where(post_id: imported_post_ids).delete_all
        Post.where(id: imported_post_ids).update_all(version: 1, public_version: 1)

        puts "  Deleted #{deleted} revision(s), reset version counters for #{imported_post_ids.size} post(s)."
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
            puts "MySQL Query Error: #{e.message}"
            []
        end
    end
end

ImportScripts::IPBoard4Custom.new.execute