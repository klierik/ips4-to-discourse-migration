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

# =============================================================================
# ipboard4_remove_scam_profiles.rb
#
# Identifies and removes SCAM Gmail accounts from Discourse.
#
# A user is a SCAM candidate when ALL of the following are true:
#   1. Post count   == 0  (never posted)
#   2. Days visited == 0  (never used the forum)
#   3. At least one of the Gmail rules below applies:
#
# Gmail rules (Google treats dots in local part as insignificant):
#   A) 2+ dots in local part  — e.g. a.b.c@gmail.com  (suspicious; 1 dot is OK)
#   B) Duplicate normalized email — e.g. ma.il@gmail.com exists alongside
#      mail@gmail.com (both normalize to "mail@gmail.com").
#      When a duplicate pair is found, the account with MORE dots is flagged.
#      If both have the same dot count, the later-created account is flagged.
#      If BOTH have 0 activity, BOTH are flagged independently.
#
# Usage (inside Discourse Docker container):
#   docker exec -it forum-discourse su discourse -c \
#     'RAILS_ENV=production bundle exec ruby /shared/ipboard4-migration/ipboard4_remove_scam_profiles.rb'
#
# Dry-run (preview only — nothing deleted):
#   DRY_RUN=1 ... bundle exec ruby /shared/ipboard4-migration/ipboard4_remove_scam_profiles.rb
# =============================================================================

require "fileutils"
require File.expand_path("/var/www/discourse/config/environment")

class RemoveScamProfiles

  REASON_MULTI_DOT = :multi_dot   # 2+ dots in Gmail local part
  REASON_DUPLICATE = :duplicate   # same normalized Gmail as another user

  def initialize
    @dry_run    = ENV["DRY_RUN"].present? && ENV["DRY_RUN"] != "0"
    @started_at = Time.now
    @stats      = {
      gmail_scanned:     0,
      flagged_multi_dot: 0,
      flagged_duplicate: 0,
      skipped_activity:  0,
      deleted:           0,
      failed:            0,
    }

    log_dir   = File.join(File.dirname(__FILE__), "logs")
    FileUtils.mkdir_p(log_dir)
    @log_path = File.join(log_dir, "remove_scam_#{Time.now.strftime("%Y-%m-%d_%H-%M-%S")}.log")
    @log_file = File.open(@log_path, "w")
    @log_file.sync = true
    @log_file.puts "# ipboard4_remove_scam_profiles — #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}"
    @log_file.puts "# Mode: #{@dry_run ? "DRY RUN" : "LIVE"}"
    @log_file.puts ""
  end

  def run
    puts "Starting SCAM profile removal..."
    puts "DRY RUN MODE — no accounts will be deleted" if @dry_run
    puts "Log: #{@log_path}"
    puts ""

    # ------------------------------------------------------------------
    # Step 1: Pull all Gmail users via pluck.
    # Note: email lives in user_emails, not in the users table.
    # Returns: [[user_id, email, created_at], ...]
    # ------------------------------------------------------------------
    puts "Building Gmail normalization index..."

    gmail_rows = User
      .where("users.id > 0")
      .joins("INNER JOIN user_emails ON user_emails.user_id = users.id AND user_emails.\"primary\" = TRUE")
      .where("user_emails.email ILIKE ?", "%@gmail.com")
      .pluck("users.id", "users.username", "user_emails.email", "users.created_at")

    @stats[:gmail_scanned] = gmail_rows.size

    # normalized local (dots removed) => [{id:, username:, email:, created_at:}, ...]
    normalized_index = Hash.new { |h, k| h[k] = [] }
    gmail_rows.each do |(id, username, email, created_at)|
      normalized_index[normalize_local(email)] << { id: id, username: username, email: email, created_at: created_at }
    end

    duplicate_normals = normalized_index.select { |_, entries| entries.size > 1 }
    puts "  #{@stats[:gmail_scanned]} Gmail accounts found"
    puts "  #{normalized_index.size} unique normalized addresses"
    puts "  #{duplicate_normals.size} normalized addresses with duplicate accounts"
    puts ""

    # ------------------------------------------------------------------
    # Step 2: Determine rule matches (before activity check)
    # ------------------------------------------------------------------
    raw_candidates = []

    gmail_rows.each do |(user_id, username, email, created_at)|
      local     = local_part(email)
      dot_count = local.count(".")
      norm      = normalize_local(email)
      reasons   = []

      # Rule A: 2+ dots
      reasons << REASON_MULTI_DOT if dot_count >= 2

      # Rule B: duplicate — flag this user if it has more dots than a sibling,
      # or the same dots but was created later.
      other_entries = normalized_index[norm].reject { |e| e[:id] == user_id }
      if other_entries.any?
        other_entries.each do |other|
          other_dots = local_part(other[:email]).count(".")
          if dot_count > other_dots ||
             (dot_count == other_dots && created_at > other[:created_at])
            reasons << REASON_DUPLICATE
            break
          end
        end
      end

      next if reasons.empty?

      raw_candidates << {
        id:         user_id,
        username:   username,
        email:      email,
        created_at: created_at,
        reasons:    reasons.uniq,
        dots:       dot_count,
        norm:       norm,
      }
    end

    puts "Gmail rule matches (before activity filter): #{raw_candidates.size}"

    # ------------------------------------------------------------------
    # Step 3: Activity filter — bulk-fetch UserStat for all candidates
    # ------------------------------------------------------------------
    candidate_ids = raw_candidates.map { |c| c[:id] }
    stat_by_uid   = UserStat
      .where(user_id: candidate_ids)
      .pluck(:user_id, :post_count, :days_visited)
      .each_with_object({}) { |(uid, pc, dv), h| h[uid] = { post_count: pc, days_visited: dv } }

    candidates = []

    raw_candidates.each do |c|
      stat         = stat_by_uid[c[:id]] || {}
      post_count   = stat[:post_count].to_i
      days_visited = stat[:days_visited].to_i

      if post_count > 0 || days_visited > 0
        msg = "SKIP  id=#{c[:id]} username=#{c[:username]} #{c[:email]} | #{c[:reasons].join("+")} | " \
              "posts=#{post_count} days_visited=#{days_visited}"
        puts msg
        @log_file.puts msg
        @stats[:skipped_activity] += 1
        next
      end

      c[:reasons].each do |r|
        @stats[:flagged_multi_dot] += 1 if r == REASON_MULTI_DOT
        @stats[:flagged_duplicate] += 1 if r == REASON_DUPLICATE
      end

      candidates << c
    end

    puts ""
    puts "After activity filter: #{candidates.size} candidates to delete"
    puts "  multi-dot: #{@stats[:flagged_multi_dot]}, " \
         "duplicate: #{@stats[:flagged_duplicate]}"
    puts ""

    # ------------------------------------------------------------------
    # Step 4: Load User objects and delete (or dry-run report)
    # ------------------------------------------------------------------
    candidates.each do |c|
      user = User.find_by(id: c[:id])
      unless user
        @log_file.puts "[#{ts}] MISSING id=#{c[:id]} #{c[:email]} (already deleted?)"
        next
      end

      reason_str = c[:reasons].map(&:to_s).join(", ")
      prefix     = @dry_run ? "[DRY RUN] " : ""

      line = "#{prefix}DELETE id=#{user.id} username=#{user.username} " \
             "email=#{c[:email]} | #{reason_str} | dots=#{c[:dots]}"
      puts line
      @log_file.puts "[#{ts}] #{line}"

      next if @dry_run

      begin
        UserDestroyer.new(Discourse.system_user).destroy(
          user,
          context:      "Automated SCAM removal: #{reason_str}",
          block_email:  false,
          block_ip:     false,
          delete_posts: true,
        )
        @stats[:deleted] += 1
      rescue => e
        err = "  ERROR id=#{user.id} #{c[:email]}: #{e.class}: #{e.message}"
        puts err
        @log_file.puts err
        @stats[:failed] += 1
      end
    end

    print_summary
  end

  private

  def local_part(email)
    email.to_s.downcase.split("@").first.to_s
  end

  def normalize_local(email)
    local_part(email).gsub(".", "")
  end

  def ts
    Time.now.strftime("%Y-%m-%d %H:%M:%S")
  end

  def print_summary
    elapsed       = (Time.now - @started_at).to_i
    h, rem        = elapsed.divmod(3600)
    m, s          = rem.divmod(60)
    st            = @stats
    total_flagged = st[:flagged_multi_dot] + st[:flagged_duplicate]

    puts ""
    puts "=" * 80
    puts "  Final Summary"
    puts "-" * 80
    puts format("  %-26s %s",   "Elapsed time:",            format("%02d:%02d:%02d", h, m, s))
    puts format("  %-26s %s",   "Mode:",                    @dry_run ? "DRY RUN (no changes)" : "LIVE")
    puts "-" * 80
    puts format("  %-26s %11d", "Gmail accounts scanned:",  st[:gmail_scanned])
    puts format("  %-26s %11d", "Flagged (multi-dot):",     st[:flagged_multi_dot])
    puts format("  %-26s %11d", "Flagged (duplicate):",     st[:flagged_duplicate])
    puts format("  %-26s %11d", "Skipped (has activity):",  st[:skipped_activity])
    puts format("  %-26s %11d", "Total flagged:",           total_flagged)
    puts "-" * 80
    puts format("  %-26s %11d", "Deleted:",                 st[:deleted])
    puts format("  %-26s %11d", "Failed:",                  st[:failed])
    puts "=" * 80
    if @dry_run
      puts "  DRY RUN MODE — no accounts were deleted"
      puts "=" * 80
    end

    @log_file.puts ""
    @log_file.puts "# --- Summary ---"
    @log_file.puts "# Elapsed:        #{format("%02d:%02d:%02d", h, m, s)}"
    @log_file.puts "# Mode:           #{@dry_run ? "DRY RUN" : "LIVE"}"
    @log_file.puts "# Scanned:        #{st[:gmail_scanned]}"
    @log_file.puts "# Flagged (dot):  #{st[:flagged_multi_dot]}"
    @log_file.puts "# Flagged (dup):  #{st[:flagged_duplicate]}"
    @log_file.puts "# Skipped:        #{st[:skipped_activity]}"
    @log_file.puts "# Deleted:        #{st[:deleted]}"
    @log_file.puts "# Failed:         #{st[:failed]}"
    @log_file.puts "# Dry run:        #{@dry_run}"
    @log_file.close

    puts "Log: #{@log_path}"
  end
end

RemoveScamProfiles.new.run
