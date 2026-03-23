# frozen_string_literal: true

# =============================================================================
# ipboard4_import_avatars.rb
#
# Standalone script to sync user avatars from IPS4 into an existing Discourse
# instance. Safe to re-run: skips users who already have a custom avatar set.
#
# Supports:
#   - Local avatars (pp_main_photo → file in UPLOADS_DIR)
#   - External avatars (pp_photo_type = 'url' / 'social' → pp_photo_url)
#
# Usage (inside Discourse Docker container):
#   docker exec -it forum-discourse su discourse -c \
#     'RAILS_ENV=production bundle exec ruby /shared/ipboard4-migration/ipboard4_import_avatars.rb'
# =============================================================================

require "mysql2"
require "yaml"
require "tempfile"
require "open-uri"
require "uri"
require "fileutils"
require File.expand_path("/var/www/discourse/script/import_scripts/base.rb")

class ImportScripts::IPBoard4AvatarUpdater < ImportScripts::Base
    # Config search priority: first /shared/ (Docker volume), then next to the script
    CONFIG_PATHS = [
        File.expand_path("/shared/ipboard4-migration/ipboard4_config.yml"),
        File.expand_path("/shared/ipboard4_config.yml"),
        File.expand_path(File.dirname(__FILE__) + "/ipboard4-migration/ipboard4_config.yml"),
        File.expand_path(File.dirname(__FILE__) + "/ipboard4_config.yml"),
    ]
    CONFIG_PATH = CONFIG_PATHS.find { |p| File.exist?(p) } || (raise "Could not find ipboard4_config.yml")
    CONFIG = YAML.load_file(CONFIG_PATH)

    BATCH_SIZE   = CONFIG.dig("import", "batch_size") || 5000
    UPLOADS_DIR  = CONFIG.dig("import", "uploads_dir") || "/mnt/ips4_uploads"
    TABLE_PREFIX = CONFIG.dig("database", "table_prefix") || "ibf2_"

    # Maximum size of downloaded remote avatars (5MB)
    MAX_REMOTE_AVATAR_BYTES = 5 * 1024 * 1024

    def initialize
        super

        @client = Mysql2::Client.new(
          host:     ENV["DB_HOST"] || CONFIG.dig("database", "host") || "localhost",
          username: ENV["DB_USER"] || CONFIG.dig("database", "username") || "root",
          password: ENV.has_key?("DB_PW") ? ENV["DB_PW"] : CONFIG.dig("database", "password").to_s,
          database: ENV["DB_NAME"] || CONFIG.dig("database", "name") || "ips4",
          port:     CONFIG.dig("database", "port") || 3306
        )
        @client.query("SET NAMES utf8mb4")
    end

    def execute
        puts "Starting avatar import/update..."
        puts "Using config from: #{CONFIG_PATH}"
        puts "Uploads dir: #{UPLOADS_DIR}"

        log_dir   = "/shared/ipboard4-migration/logs"
        FileUtils.mkdir_p(log_dir)
        @log_path = File.join(log_dir, "import_avatars_#{Time.now.strftime("%Y-%m-%d_%H-%M-%S")}.log")
        @log_file = File.open(@log_path, "w")
        @log_file.sync = true
        @log_file.puts "# ipboard4_import_avatars — #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}"
        @log_file.puts "# Config: #{CONFIG_PATH}"
        @log_file.puts "# Uploads dir: #{UPLOADS_DIR}"
        @log_file.puts ""
        puts "Log: #{@log_path}"

        # Relax attachment size during upload
        SiteSetting.max_attachment_size_kb = CONFIG.dig("import", "max_attachment_size_kb") || 262144

        total_count    = 0
        skipped_count  = 0
        updated_local  = 0
        updated_remote = 0
        failed_count   = 0
        no_file_count  = 0

        # Detect which avatar columns exist in this IPS4 version (columns differ across versions)
        available_columns = @client.query(<<~SQL).map { |r| r["COLUMN_NAME"] }
            SELECT COLUMN_NAME
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE()
              AND TABLE_NAME   = '#{TABLE_PREFIX}core_members'
              AND COLUMN_NAME  IN ('pp_main_photo', 'pp_photo_type', 'pp_photo_url')
        SQL
        has_photo_url  = available_columns.include?("pp_photo_url")
        has_photo_type = available_columns.include?("pp_photo_type")
        puts "Available avatar columns: #{available_columns.inspect}"

        extra_select = []
        extra_where  = ["(m.pp_main_photo IS NOT NULL AND m.pp_main_photo != '')"]
        extra_select << "m.pp_photo_type" if has_photo_type
        if has_photo_url
            extra_select << "m.pp_photo_url"
            extra_where  << "(m.pp_photo_url IS NOT NULL AND m.pp_photo_url != '')"
        end

        last_member_id = 0

        loop do
            rows = @client.query(<<~SQL)
                SELECT m.member_id  AS id,
                       m.name       AS username,
                       m.pp_main_photo#{extra_select.any? ? ", " + extra_select.join(", ") : ""}
                FROM #{TABLE_PREFIX}core_members AS m
                WHERE m.member_id > #{last_member_id}
                  AND (#{extra_where.join(" OR ")})
                ORDER BY m.member_id
                LIMIT #{BATCH_SIZE}
            SQL

            break if rows.count.zero?
            last_member_id = rows.to_a.last["id"]
            total_count   += rows.count

            rows.each do |row|
                ips4_id    = row["id"]
                username   = row["username"].to_s
                photo_path = row["pp_main_photo"].to_s
                photo_type = has_photo_type ? row["pp_photo_type"].to_s : "" # 'custom', 'url', 'social', 'none', etc.
                photo_url  = has_photo_url ? row["pp_photo_url"].to_s : ""

                # Find the already-imported Discourse user
                discourse_user_id = user_id_from_imported_user_id(ips4_id)
                unless discourse_user_id
                    skipped_count += 1
                    next
                end

                discourse_user = User.find_by(id: discourse_user_id)
                unless discourse_user
                    skipped_count += 1
                    next
                end

                # Skip if user already has a custom avatar
                if discourse_user.uploaded_avatar_id.present?
                    skipped_count += 1
                    next
                end

                # -------------------------------------------------------
                # Determine avatar source: local file or remote URL
                # IPS4 can store URLs directly in pp_main_photo (Google/social login)
                # -------------------------------------------------------
                avatar_set = false

                # 1. If pp_main_photo is a URL (starts with http) → download from remote
                if photo_path.present? && photo_path.start_with?("http")
                    upload = upload_avatar_from_url(discourse_user, photo_path, username, ips4_id)
                    if upload
                        updated_remote += 1
                        puts "Updated REMOTE avatar for #{username} (#{ips4_id}): #{photo_path}"
                        avatar_set = true
                    else
                        failed_count += 1
                    end

                # 2. If pp_main_photo is a local file path → upload from disk
                elsif photo_path.present?
                    full_path = File.join(UPLOADS_DIR, photo_path)
                    if File.exist?(full_path)
                        upload = upload_avatar_from_file(discourse_user, full_path, File.basename(full_path), username, ips4_id)
                        if upload
                            updated_local += 1
                            puts "Updated LOCAL avatar for #{username} (#{ips4_id}): #{photo_path}"
                            avatar_set = true
                        else
                            failed_count += 1
                        end
                    end
                end

                # 3. Fall back to pp_photo_url (if column exists and has a value)
                if !avatar_set && photo_url.present? && photo_url.start_with?("http")
                    upload = upload_avatar_from_url(discourse_user, photo_url, username, ips4_id)
                    if upload
                        updated_remote += 1
                        puts "Updated REMOTE avatar (fallback) for #{username} (#{ips4_id}): #{photo_url}"
                        avatar_set = true
                    else
                        failed_count += 1
                    end
                end

                unless avatar_set
                    no_file_count += 1
                end
            end
        end

        puts ""
        puts "=" * 60
        puts "Avatar import complete."
        puts "  Total IPS4 users processed   : #{total_count}"
        puts "  Updated from local file      : #{updated_local}"
        puts "  Updated from remote URL (R)  : #{updated_remote}"
        puts "  Skipped (already set or      : #{skipped_count}"
        puts "    no Discourse user found)   "
        puts "  No source (local or URL)     : #{no_file_count}"
        puts "  Failed to upload             : #{failed_count}"
        puts "=" * 60

        if @log_file
            @log_file.puts ""
            @log_file.puts "# --- Summary ---"
            @log_file.puts "# Total processed : #{total_count}"
            @log_file.puts "# Updated local   : #{updated_local}"
            @log_file.puts "# Updated remote  : #{updated_remote}"
            @log_file.puts "# No source       : #{no_file_count}"
            @log_file.puts "# Skipped         : #{skipped_count}"
            @log_file.puts "# Failed          : #{failed_count}"
            @log_file.close
            puts "Log: #{@log_path}" if failed_count > 0
        end
    end

    private

    # Upload avatar from a local filesystem path
    def upload_avatar_from_file(discourse_user, full_path, filename, username, ips4_id)
        begin
            upload = create_upload(discourse_user.id, full_path, filename)
            if upload&.persisted?
                apply_avatar(discourse_user, upload)
                upload
            else
                error_msg = upload ? upload.errors.full_messages.join(", ") : "Upload is nil"
                puts "\nFailed to upload local avatar for #{username} (#{ips4_id}): #{error_msg}"
                @log_file&.puts "[#{Time.now.strftime("%Y-%m-%d %H:%M:%S")}] LOCAL ips4=#{ips4_id} user=#{username} path=#{full_path} | #{error_msg}"
                nil
            end
        rescue StandardError => e
            puts "\nException uploading local avatar for #{username} (#{ips4_id}): #{e.message}"
            @log_file&.puts "[#{Time.now.strftime("%Y-%m-%d %H:%M:%S")}] LOCAL ips4=#{ips4_id} user=#{username} path=#{full_path} | #{e.class}: #{e.message}"
            nil
        end
    end

    # Download an external avatar URL into a tempfile, then upload to Discourse
    def upload_avatar_from_url(discourse_user, url, username, ips4_id)
        begin
            uri = URI.parse(url)
            # Build a filename from the URL (strip query params)
            filename = File.basename(uri.path).presence || "avatar_#{ips4_id}.jpg"
            # Ensure extension
            filename += ".jpg" unless filename.include?(".")

            Tempfile.create(["ips4_avatar_#{ips4_id}_", File.extname(filename)], binmode: true) do |tmp|
                URI.open(url,
                    "User-Agent"     => "Mozilla/5.0 (Forum Migration)",
                    read_timeout:    15,
                    open_timeout:    10,
                ) do |stream|
                    # Stream with size limit
                    bytes_read = 0
                    while (chunk = stream.read(64 * 1024))
                        bytes_read += chunk.bytesize
                        if bytes_read > MAX_REMOTE_AVATAR_BYTES
                            puts "\nRemote avatar too large (>5MB) for #{username} (#{ips4_id}), skipping"
                            return nil
                        end
                        tmp.write(chunk)
                    end
                end

                tmp.flush
                tmp.rewind

                upload = create_upload(discourse_user.id, tmp.path, filename)
                if upload&.persisted?
                    apply_avatar(discourse_user, upload)
                    return upload
                else
                    error_msg = upload ? upload.errors.full_messages.join(", ") : "Upload is nil"
                    puts "\nFailed to upload remote avatar for #{username} (#{ips4_id}) from #{url}: #{error_msg}"
                    @log_file&.puts "[#{Time.now.strftime("%Y-%m-%d %H:%M:%S")}] REMOTE ips4=#{ips4_id} user=#{username} url=#{url} | #{error_msg}"
                    return nil
                end
            end
        rescue OpenURI::HTTPError => e
            puts "\nHTTP error downloading avatar for #{username} (#{ips4_id}) from #{url}: #{e.message}"
            @log_file&.puts "[#{Time.now.strftime("%Y-%m-%d %H:%M:%S")}] REMOTE ips4=#{ips4_id} user=#{username} url=#{url} | HTTP #{e.message}"
            nil
        rescue StandardError => e
            puts "\nException downloading remote avatar for #{username} (#{ips4_id}) from #{url}: #{e.message}"
            @log_file&.puts "[#{Time.now.strftime("%Y-%m-%d %H:%M:%S")}] REMOTE ips4=#{ips4_id} user=#{username} url=#{url} | #{e.class}: #{e.message}"
            nil
        end
    end

    # Set the upload as the user's avatar
    def apply_avatar(discourse_user, upload)
        discourse_user.create_user_avatar unless discourse_user.user_avatar
        discourse_user.user_avatar.update!(custom_upload_id: upload.id)
        discourse_user.update!(uploaded_avatar_id: upload.id)
    end

    # -------------------------------------------------------
    # Override base class post-processing to skip steps that
    # are irrelevant for an avatar-only update run.
    # -------------------------------------------------------
    def update_topic_status;             end
    def update_bumped_at;                end
    def update_last_posted_at;          end
    def update_last_seen_at;            end
    def update_first_post_created_at;   end
    def update_user_post_count;         end
    def update_user_topic_count;        end
    def update_user_digest_attempted_at; end
    def update_topic_users;             end
    def update_post_timings;            end
    def update_topic_featured_link_allowed_users; end
    def update_topic_count_stats;       end
    def update_featured_topics_in_categories; end
    def reset_topic_counters;           end

    def mysql_query(sql)
        @client.query(sql)
    end
end

ImportScripts::IPBoard4AvatarUpdater.new.perform
