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
# ipboard4_recalculate_user_stats.rb
#
# Recalculates user_stats counters from actual post/topic data.
# Safe to re-run at any time — updates all non-system users in place.
#
# What is recalculated:
#   - post_count   : regular posts (post_type=1) that are not deleted
#   - topic_count  : topics opened by the user that are not deleted/archived
#
# Typical use case: after migration, user_stats counters may be stale because
# imported posts were later deleted or soft-deleted without decrementing the
# cached counter.
#
# Usage (inside Discourse Docker container):
#   docker exec -it forum-discourse su discourse -c \
#     'RAILS_ENV=production bundle exec ruby /shared/ipboard4-migration/ipboard4_recalculate_user_stats.rb'
#
# Dry-run (show what would change, nothing written):
#   DRY_RUN=1 ... bundle exec ruby /shared/ipboard4-migration/ipboard4_recalculate_user_stats.rb
# =============================================================================

require "fileutils"
require File.expand_path("/var/www/discourse/config/environment")

class RecalculateUserStats

  def initialize
    @dry_run    = ENV["DRY_RUN"].present? && ENV["DRY_RUN"] != "0"
    @started_at = Time.now
    @stats      = { updated: 0, unchanged: 0, failed: 0 }

    log_dir   = File.join(File.dirname(__FILE__), "logs")
    FileUtils.mkdir_p(log_dir)
    @log_path = File.join(log_dir, "recalculate_user_stats_#{Time.now.strftime("%Y-%m-%d_%H-%M-%S")}.log")
    @log_file = File.open(@log_path, "w")
    @log_file.sync = true
    @log_file.puts "# ipboard4_recalculate_user_stats — #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}"
    @log_file.puts "# Mode: #{@dry_run ? "DRY RUN" : "LIVE"}"
    @log_file.puts ""
  end

  def run
    puts "Starting user stats recalculation..."
    puts "DRY RUN MODE — no changes will be written" if @dry_run
    puts "Log: #{@log_path}"
    puts ""

    total = DB.query_single("SELECT COUNT(*) FROM user_stats WHERE user_id > 0").first
    puts "User stats rows to process: #{total}"
    puts ""

    if @dry_run
      run_dry
    else
      run_live
    end

    print_summary
  end

  private

  # ---------------------------------------------------------------------------
  # Live mode: single bulk UPDATE per counter — fast, no per-row overhead
  # ---------------------------------------------------------------------------
  def run_live
    puts "Recalculating post_count..."
    rows = DB.exec(<<~SQL)
      UPDATE user_stats us
      SET post_count = sub.cnt
      FROM (
        SELECT user_id, COUNT(*) AS cnt
        FROM posts
        WHERE deleted_at IS NULL
          AND post_type  = #{Post.types[:regular]}
        GROUP BY user_id
      ) sub
      WHERE us.user_id = sub.user_id
        AND us.user_id > 0
        AND us.post_count <> sub.cnt
    SQL
    puts "  post_count updated for #{rows} users"
    @log_file.puts "post_count: #{rows} rows updated"

    # Zero out post_count for users with no remaining regular posts
    zeroed = DB.exec(<<~SQL)
      UPDATE user_stats
      SET post_count = 0
      WHERE user_id > 0
        AND post_count <> 0
        AND user_id NOT IN (
          SELECT DISTINCT user_id
          FROM posts
          WHERE deleted_at IS NULL
            AND post_type = #{Post.types[:regular]}
        )
    SQL
    puts "  post_count zeroed for #{zeroed} users (all posts deleted)"
    @log_file.puts "post_count zeroed: #{zeroed} rows"

    puts ""
    puts "Recalculating topic_count..."
    rows = DB.exec(<<~SQL)
      UPDATE user_stats us
      SET topic_count = sub.cnt
      FROM (
        SELECT user_id, COUNT(*) AS cnt
        FROM topics
        WHERE deleted_at IS NULL
          AND archetype  = '#{Archetype.default}'
          AND user_id    > 0
        GROUP BY user_id
      ) sub
      WHERE us.user_id = sub.user_id
        AND us.user_id > 0
        AND us.topic_count <> sub.cnt
    SQL
    puts "  topic_count updated for #{rows} users"
    @log_file.puts "topic_count: #{rows} rows updated"

    zeroed = DB.exec(<<~SQL)
      UPDATE user_stats
      SET topic_count = 0
      WHERE user_id > 0
        AND topic_count <> 0
        AND user_id NOT IN (
          SELECT DISTINCT user_id
          FROM topics
          WHERE deleted_at IS NULL
            AND archetype = '#{Archetype.default}'
            AND user_id   > 0
        )
    SQL
    puts "  topic_count zeroed for #{zeroed} users (all topics deleted)"
    @log_file.puts "topic_count zeroed: #{zeroed} rows"

    @stats[:updated] = rows + zeroed
  end

  # ---------------------------------------------------------------------------
  # Dry-run mode: compute real values and compare, report differences only
  # ---------------------------------------------------------------------------
  def run_dry
    real_post_counts = DB.query(<<~SQL).each_with_object({}) { |r, h| h[r.user_id] = r.cnt }
      SELECT user_id, COUNT(*) AS cnt
      FROM posts
      WHERE deleted_at IS NULL
        AND post_type = #{Post.types[:regular]}
      GROUP BY user_id
    SQL

    real_topic_counts = DB.query(<<~SQL).each_with_object({}) { |r, h| h[r.user_id] = r.cnt }
      SELECT user_id, COUNT(*) AS cnt
      FROM topics
      WHERE deleted_at IS NULL
        AND archetype = '#{Archetype.default}'
        AND user_id   > 0
      GROUP BY user_id
    SQL

    DB.query("SELECT user_id, post_count, topic_count FROM user_stats WHERE user_id > 0").each do |row|
      uid          = row.user_id
      real_posts   = real_post_counts[uid].to_i
      real_topics  = real_topic_counts[uid].to_i
      cur_posts    = row.post_count.to_i
      cur_topics   = row.topic_count.to_i

      if real_posts != cur_posts || real_topics != cur_topics
        user = User.find_by(id: uid)
        line = "[DRY RUN] user_id=#{uid} username=#{user&.username} | " \
               "post_count #{cur_posts}→#{real_posts}  " \
               "topic_count #{cur_topics}→#{real_topics}"
        puts line
        @log_file.puts line
        @stats[:updated] += 1
      else
        @stats[:unchanged] += 1
      end
    end

    puts ""
    puts "Would update #{@stats[:updated]} users (#{@stats[:unchanged]} unchanged)"
  end

  def print_summary
    elapsed = (Time.now - @started_at).to_i
    h, rem  = elapsed.divmod(3600)
    m, s    = rem.divmod(60)
    st      = @stats

    puts ""
    puts "=" * 80
    puts "  Final Summary"
    puts "-" * 80
    puts format("  %-22s %s", "Elapsed time:", format("%02d:%02d:%02d", h, m, s))
    puts format("  %-22s %s", "Mode:",         @dry_run ? "DRY RUN (no changes)" : "LIVE")
    puts "-" * 80
    puts format("  %-22s %11d", "Updated:",   st[:updated])
    puts format("  %-22s %11d", "Unchanged:", st[:unchanged]) if @dry_run
    puts format("  %-22s %11d", "Failed:",    st[:failed])
    puts "=" * 80
    if @dry_run
      puts "  DRY RUN MODE — no changes were written"
      puts "=" * 80
    end

    @log_file.puts ""
    @log_file.puts "# --- Summary ---"
    @log_file.puts "# Elapsed:   #{format("%02d:%02d:%02d", h, m, s)}"
    @log_file.puts "# Mode:      #{@dry_run ? "DRY RUN" : "LIVE"}"
    @log_file.puts "# Updated:   #{st[:updated]}"
    @log_file.puts "# Unchanged: #{st[:unchanged]}"
    @log_file.puts "# Failed:    #{st[:failed]}"
    @log_file.puts "# Dry run:   #{@dry_run}"
    @log_file.close

    puts "Log: #{@log_path}"
  end
end

RecalculateUserStats.new.run
