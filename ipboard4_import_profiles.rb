# frozen_string_literal: true

# =============================================================================
# ipboard4_import_profiles.rb
#
# Standalone script to update existing Discourse user profiles from IPS4 data.
# Safe to re-run: only updates fields that differ from current Discourse values.
#
# What it updates (only when the value differs):
#   - username  : Cyrillic names are transliterated to Latin
#                 e.g. "Игорь Ермаков" → "Igor_Ermakov"
#                 Spaces → underscores. Non-allowed chars stripped.
#   - name      : full display name (stored as user.name in Discourse)
#   - title     : member_title
#   - bio_raw   : about_me / field_11 from core_pfields_content
#   - date_of_birth
#   - location  : member_location (if column exists in IPS4)
#   - website   : pp_website (if column exists in IPS4)
#
# Usage (inside Discourse Docker container):
#   docker exec -it forum-discourse su discourse -c \
#     'RAILS_ENV=production bundle exec ruby /shared/ipboard4-migration/ipboard4_import_profiles.rb'
#
# Dry-run (preview changes, nothing written):
#   DRY_RUN=1 ... bundle exec ruby /shared/ipboard4-migration/ipboard4_import_profiles.rb
# =============================================================================

require "mysql2"
require "yaml"
require "cgi"
require "fileutils"
require File.expand_path("/var/www/discourse/script/import_scripts/base.rb")

class ImportScripts::IPBoard4ProfileUpdater < ImportScripts::Base

  CONFIG_PATHS = [
    File.expand_path("/shared/ipboard4-migration/ipboard4_config.yml"),
    File.expand_path("/shared/ipboard4_config.yml"),
    File.expand_path(File.dirname(__FILE__) + "/ipboard4-migration/ipboard4_config.yml"),
    File.expand_path(File.dirname(__FILE__) + "/ipboard4_config.yml"),
  ]
  CONFIG_PATH = CONFIG_PATHS.find { |p| File.exist?(p) } || (raise "Could not find ipboard4_config.yml")
  CONFIG      = YAML.load_file(CONFIG_PATH)

  BATCH_SIZE   = CONFIG.dig("import", "batch_size") || 5000
  TABLE_PREFIX = CONFIG.dig("database", "table_prefix") || "ibf2_"

  # ---------------------------------------------------------------------------
  # Cyrillic → Latin transliteration table (Russian + Ukrainian)
  # ---------------------------------------------------------------------------
  CYRILLIC_TRANSLIT = {
    "А" => "A",    "а" => "a",
    "Б" => "B",    "б" => "b",
    "В" => "V",    "в" => "v",
    "Г" => "G",    "г" => "g",
    "Д" => "D",    "д" => "d",
    "Е" => "E",    "е" => "e",
    "Ё" => "Yo",   "ё" => "yo",
    "Ж" => "Zh",   "ж" => "zh",
    "З" => "Z",    "з" => "z",
    "И" => "I",    "и" => "i",
    "Й" => "Y",    "й" => "y",
    "К" => "K",    "к" => "k",
    "Л" => "L",    "л" => "l",
    "М" => "M",    "м" => "m",
    "Н" => "N",    "н" => "n",
    "О" => "O",    "о" => "o",
    "П" => "P",    "п" => "p",
    "Р" => "R",    "р" => "r",
    "С" => "S",    "с" => "s",
    "Т" => "T",    "т" => "t",
    "У" => "U",    "у" => "u",
    "Ф" => "F",    "ф" => "f",
    "Х" => "Kh",   "х" => "kh",
    "Ц" => "Ts",   "ц" => "ts",
    "Ч" => "Ch",   "ч" => "ch",
    "Ш" => "Sh",   "ш" => "sh",
    "Щ" => "Shch", "щ" => "shch",
    "Ъ" => "",     "ъ" => "",
    "Ы" => "Y",    "ы" => "y",
    "Ь" => "",     "ь" => "",
    "Э" => "E",    "э" => "e",
    "Ю" => "Yu",   "ю" => "yu",
    "Я" => "Ya",   "я" => "ya",
    # Ukrainian extras
    "І" => "I",    "і" => "i",
    "Ї" => "Yi",   "ї" => "yi",
    "Є" => "Ye",   "є" => "ye",
    "Ґ" => "G",    "ґ" => "g",
  }.freeze

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

    @dry_run = ENV["DRY_RUN"].present? && ENV["DRY_RUN"] != "0"
  end

  def execute
    puts "Starting user profile import..."
    puts "Using config from: #{CONFIG_PATH}"
    puts "DRY RUN MODE — no changes will be written to Discourse" if @dry_run

    @started_at = Time.now

    log_dir   = "/shared/ipboard4-migration/logs"
    FileUtils.mkdir_p(log_dir)
    @log_path = File.join(log_dir, "import_profiles_#{Time.now.strftime("%Y-%m-%d_%H-%M-%S")}.log")
    @log_file = File.open(@log_path, "w")
    @log_file.sync = true
    @log_file.puts "# ipboard4_import_profiles — #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}"
    @log_file.puts "# Config: #{CONFIG_PATH}"
    @log_file.puts ""
    puts "Log: #{@log_path}"

    # ------------------------------------------------------------------
    # Detect optional columns in IPS4 schema (differ across versions)
    # ------------------------------------------------------------------
    members_cols = @client.query(<<~SQL).map { |r| r["COLUMN_NAME"] }
      SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE()
        AND TABLE_NAME   = '#{TABLE_PREFIX}core_members'
        AND COLUMN_NAME  IN ('pp_about_me', 'member_location', 'pp_website', 'timezone')
    SQL

    # Prefer field_11 in core_pfields_content for about_me (more complete)
    about_me_source = nil
    begin
      @client.query("SHOW COLUMNS FROM #{TABLE_PREFIX}core_pfields_content").each do |r|
        about_me_source = :pfields if r["Field"] == "field_11"
      end
    rescue Mysql2::Error
      # Table doesn't exist in this IPS4 version — fall through
    end
    about_me_source ||= :members if members_cols.include?("pp_about_me")

    @has_location = members_cols.include?("member_location")
    @has_website  = members_cols.include?("pp_website")
    @has_timezone = members_cols.include?("timezone")

    about_me_sql = case about_me_source
                   when :pfields then "NULLIF(TRIM(p.field_11), '')"
                   when :members then "NULLIF(TRIM(m.pp_about_me), '')"
                   else "NULL"
                   end
    location_sql = @has_location ? "NULLIF(TRIM(m.member_location), '')" : "NULL"
    website_sql  = @has_website  ? "NULLIF(TRIM(m.pp_website), '')"      : "NULL"
    timezone_sql = @has_timezone ? "NULLIF(TRIM(m.timezone), '')"        : "NULL"
    join_sql     = about_me_source == :pfields ?
                   "LEFT JOIN #{TABLE_PREFIX}core_pfields_content AS p ON m.member_id = p.member_id" : ""

    puts "Schema: about_me=#{about_me_source || "none"}, location=#{@has_location}, website=#{@has_website}, timezone=#{@has_timezone}"

    total_users = @client.query("SELECT COUNT(*) AS count FROM #{TABLE_PREFIX}core_members").first["count"]
    puts "", "updating user profiles (#{total_users} total)..."

    @stats = {
      total:             0,
      no_discourse_user: 0,
      updated:           0,
      skipped_unchanged: 0,
      failed:            0,
    }

    last_member_id = 0

    loop do
      rows = @client.query(<<~SQL).to_a
        SELECT
          m.member_id  AS id,
          m.name,
          m.member_title AS title,
          CASE
            WHEN m.bday_year  IS NULL OR m.bday_year  = 0
              OR m.bday_month IS NULL OR m.bday_month = 0
              OR m.bday_day   IS NULL OR m.bday_day   = 0
            THEN NULL
            ELSE CONCAT(m.bday_year, '-',
                        LPAD(m.bday_month, 2, '0'), '-',
                        LPAD(m.bday_day,   2, '0'))
          END AS date_of_birth,
          #{about_me_sql} AS about_me,
          #{location_sql} AS location,
          #{website_sql}  AS website,
          #{timezone_sql} AS timezone
        FROM #{TABLE_PREFIX}core_members AS m
        #{join_sql}
        WHERE m.member_id > #{last_member_id}
        ORDER BY m.member_id
        LIMIT #{BATCH_SIZE}
      SQL

      break if rows.empty?

      last_member_id  = rows.last["id"]
      @stats[:total] += rows.size

      rows.each { |row| update_user_profile(row) }

      if @stats[:total] % 20 == 0 || @stats[:total] >= total_users
        s = @stats
        print "\rProcessing user #{s[:total]}/#{total_users} | " \
              "Updated: #{s[:updated]} | " \
              "Unchanged: #{s[:skipped_unchanged]} | " \
              "No user: #{s[:no_discourse_user]} | " \
              "Failed: #{s[:failed]}"
        STDOUT.flush
      end
    end

    puts "\nFinished user profiles: " \
         "updated=#{@stats[:updated]}, " \
         "unchanged=#{@stats[:skipped_unchanged]}, " \
         "no_user=#{@stats[:no_discourse_user]}, " \
         "failed=#{@stats[:failed]}"

    print_summary
  end

  private

  def update_user_profile(row)
    ips4_id = row["id"]

    discourse_user_id = user_id_from_imported_user_id(ips4_id)
    unless discourse_user_id
      @stats[:no_discourse_user] += 1
      return
    end

    user = User.find_by(id: discourse_user_id)
    unless user
      @stats[:no_discourse_user] += 1
      return
    end

    # Force UTF-8 on all incoming strings
    row.each_value do |v|
      next unless v.is_a?(String)
      v.force_encoding("UTF-8")
      v.encode!("UTF-8", invalid: :replace, undef: :replace, replace: "") unless v.valid_encoding?
    end

    changes = {}

    # ----------------------------------------------------------------
    # Username — transliterate Cyrillic, sanitize, check for conflict
    # ----------------------------------------------------------------
    raw_name     = row["name"].to_s.strip
    new_username = transliterate_username(raw_name, ips4_id)
    if new_username.present? && new_username != user.username
      resolved = resolve_username_conflict(new_username, user.id, ips4_id)
      changes[:username] = { from: user.username, to: resolved }
    end

    # ----------------------------------------------------------------
    # Display name (user.name in Discourse — shown in profile header)
    # Keep the original IPS4 name as display name even when username is
    # transliterated; Discourse stores them separately.
    # ----------------------------------------------------------------
    new_name = raw_name
    if new_name.present? && new_name != user.name.to_s
      changes[:name] = { from: user.name, to: new_name }
    end

    # ----------------------------------------------------------------
    # Title
    # ----------------------------------------------------------------
    new_title = CGI.unescapeHTML(row["title"].to_s.strip)
    if new_title != user.title.to_s
      changes[:title] = { from: user.title, to: new_title }
    end

    # ----------------------------------------------------------------
    # Date of birth
    # ----------------------------------------------------------------
    new_dob = begin
                row["date_of_birth"].present? ? Date.parse(row["date_of_birth"]) : nil
              rescue ArgumentError
                nil
              end
    if new_dob != user.date_of_birth
      changes[:date_of_birth] = { from: user.date_of_birth, to: new_dob }
    end

    # ----------------------------------------------------------------
    # Bio / location / website — stored on UserProfile
    # ----------------------------------------------------------------
    profile = user.user_profile

    if profile
      new_bio = strip_html(row["about_me"].to_s)
      if new_bio.present? && new_bio != profile.bio_raw.to_s
        changes[:bio_raw] = {
          from: profile.bio_raw.to_s.slice(0, 60),
          to:   new_bio.slice(0, 60),
        }
      end

      new_location = row["location"].to_s.strip
      if new_location.present? && new_location != profile.location.to_s
        changes[:location] = { from: profile.location, to: new_location }
      end

      new_website = row["website"].to_s.strip
      if new_website.present? && new_website != profile.website.to_s
        changes[:website] = { from: profile.website, to: new_website }
      end
    end

    # ----------------------------------------------------------------
    # Timezone — stored on UserOption
    # ----------------------------------------------------------------
    if @has_timezone
      new_timezone = row["timezone"].to_s.strip
      if new_timezone.present? && new_timezone != user.user_option&.timezone.to_s
        changes[:timezone] = { from: user.user_option&.timezone, to: new_timezone }
      end
    end

    if changes.empty?
      @stats[:skipped_unchanged] += 1
      return
    end

    prefix = @dry_run ? "[DRY RUN] " : ""
    puts "#{prefix}User #{user.username} (ips4=#{ips4_id}):"
    changes.each { |field, v| puts "  #{field}: #{v[:from].inspect} → #{v[:to].inspect}" }

    return if @dry_run

    begin
      User.transaction do
        # Username via UsernameChanger so @mentions in posts stay consistent
        if changes[:username]
          UsernameChanger.change(user, changes[:username][:to], Discourse.system_user)
          user.reload
        end

        user_attrs = {}
        user_attrs[:name]          = changes[:name][:to]          if changes[:name]
        user_attrs[:title]         = changes[:title][:to]         if changes[:title]
        user_attrs[:date_of_birth] = changes[:date_of_birth][:to] if changes[:date_of_birth]
        user.update!(user_attrs) if user_attrs.any?

        if profile && (changes[:bio_raw] || changes[:location] || changes[:website])
          profile_attrs = {}
          profile_attrs[:bio_raw]  = row["about_me"].to_s.strip if changes[:bio_raw]
          profile_attrs[:location] = changes[:location][:to]     if changes[:location]
          profile_attrs[:website]  = changes[:website][:to]      if changes[:website]
          profile.update!(profile_attrs)
        end

        if changes[:timezone]
          user.user_option.update!(timezone: changes[:timezone][:to])
        end
      end

      @stats[:updated] += 1
    rescue StandardError => e
      msg = "#{e.class}: #{e.message}"
      puts "  ERROR updating user #{user.username} (ips4=#{ips4_id}): #{msg}"
      @log_file&.puts "[#{Time.now.strftime("%Y-%m-%d %H:%M:%S")}] ips4=#{ips4_id} user=#{user.username} | #{msg}"
      @stats[:failed] += 1
    end
  end

  # Convert an IPS4 display name into a valid Discourse username.
  #
  # Rules applied in order:
  #   1. Transliterate Cyrillic characters to Latin equivalents
  #   2. Replace whitespace and hyphens with underscores
  #   3. Strip any remaining characters not in [a-zA-Z0-9_-]
  #   4. Collapse consecutive underscores; strip leading/trailing underscores
  #   5. Fall back to "user_<ips4_id>" if the result is too short
  #
  # Examples:
  #   "Игорь Ермаков" → "Igor_Ermakov"
  #   "Cool!@# User"  → "Cool_User"
  #   "!@#$%"         → "user_12345"
  def transliterate_username(name, ips4_id)
    s = name.dup

    # Step 1: Cyrillic → Latin
    CYRILLIC_TRANSLIT.each { |cyr, lat| s.gsub!(cyr, lat) }

    # Step 2: spaces / hyphens → underscore
    s.gsub!(/[\s\-]+/, "_")

    # Step 3: strip disallowed chars
    s.gsub!(/[^a-zA-Z0-9_\-]/, "")

    # Step 4: normalize underscores / edges
    s.gsub!(/_+/, "_")
    s.gsub!(/\A_+|_+\z/, "")

    # Step 5: fallback
    (s.length >= 2) ? s : "user_#{ips4_id}"
  end

  # If `desired` username is already taken by a *different* user, append the
  # IPS4 member ID. If that is also taken, append a short random hex suffix.
  def resolve_username_conflict(desired, current_discourse_id, ips4_id)
    existing = User.find_by_username_lower(desired.downcase)
    return desired if existing.nil? || existing.id == current_discourse_id

    candidate = "#{desired}_#{ips4_id}"
    existing2 = User.find_by_username_lower(candidate.downcase)
    return candidate if existing2.nil? || existing2.id == current_discourse_id

    "#{desired}_#{SecureRandom.hex(3)}"
  end

  # Strip HTML tags and decode entities for plain-text profile fields.
  def strip_html(html)
    CGI.unescapeHTML(html.gsub(/<[^>]+>/, " ").squeeze(" ").strip)
  end

  def print_summary
    elapsed = (Time.now - @started_at).to_i
    h, rem  = elapsed.divmod(3600)
    m, s    = rem.divmod(60)

    st = @stats

    puts ""
    puts "=" * 80
    puts "  Final Summary"
    puts "-" * 80
    puts format("  %-22s %s", "Elapsed time:", format("%02d:%02d:%02d", h, m, s))
    puts "-" * 80
    puts format("  %-22s %11s %11s %11s %11s %11s",
                "Section", "Processed", "Updated", "Unchanged", "No User", "Failed")
    puts "-" * 80
    puts format("  %-22s %11d %11d %11d %11d %11d",
                "User profiles",
                st[:total], st[:updated], st[:skipped_unchanged],
                st[:no_discourse_user], st[:failed])
    puts "=" * 80
    puts "  Updated   — profile fields changed and written to Discourse"
    puts "  Unchanged — all fields identical, no write needed"
    puts "  No User   — IPS4 member has no corresponding Discourse account"
    puts "  Failed    — exception raised during update"
    if @dry_run
      puts "-" * 80
      puts "  DRY RUN MODE — no changes were written to Discourse"
    end
    puts "=" * 80

    if @log_file
      @log_file.puts ""
      @log_file.puts "# --- Summary ---"
      @log_file.puts "# Elapsed   : #{format("%02d:%02d:%02d", h, m, s)}"
      @log_file.puts "# Processed : #{@stats[:total]}"
      @log_file.puts "# Updated   : #{@stats[:updated]}"
      @log_file.puts "# Unchanged : #{@stats[:skipped_unchanged]}"
      @log_file.puts "# No user   : #{@stats[:no_discourse_user]}"
      @log_file.puts "# Failed    : #{@stats[:failed]}"
      @log_file.puts "# Dry run   : #{@dry_run}"
      @log_file.close
      puts "Log: #{@log_path}" if @stats[:failed] > 0 || @dry_run
    end
  end

  # Override base-class post-processing steps that are irrelevant here
  def update_topic_status;                      end
  def update_bumped_at;                         end
  def update_last_posted_at;                    end
  def update_last_seen_at;                      end
  def update_first_post_created_at;             end
  def update_user_post_count;                   end
  def update_user_topic_count;                  end
  def update_user_digest_attempted_at;          end
  def update_topic_users;                       end
  def update_post_timings;                      end
  def update_topic_featured_link_allowed_users; end
  def update_topic_count_stats;                 end
  def update_featured_topics_in_categories;     end
  def reset_topic_counters;                     end

  def mysql_query(sql)
    @client.query(sql)
  end
end

ImportScripts::IPBoard4ProfileUpdater.new.perform
