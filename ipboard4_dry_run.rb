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
require "json"
require "yaml"
require File.expand_path(File.dirname(__FILE__) + "/base.rb")

class ImportScripts::IPBoard4DryRun < ImportScripts::Base
    CONFIG_PATH = File.expand_path(File.dirname(__FILE__) + "/ipboard4_config.yml")
    CONFIG = YAML.load_file(CONFIG_PATH)

    BATCH_SIZE = CONFIG.dig("import", "batch_size") || 5000
    TABLE_PREFIX = CONFIG.dig("database", "table_prefix") || "ibf2_"

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
        
        @report = {
            users: {
                total: 0,
                valid: 0,
                invalid: 0,
                errors: Hash.new(0)
            },
            topics: {
                total: 0,
                missing_users: 0
            },
            posts: {
                total: 0,
                missing_users: 0,
                missing_topics: 0
            }
        }
    end

    def execute
        puts "Starting Dry Run Validation for IPS4 Migration..."
        
        # Temporary settings for validation consistency
        SiteSetting.unicode_usernames = true
        SiteSetting.min_username_length = 2
        SiteSetting.max_username_length = 60
        SiteSetting.allow_uppercase_posts = true
        SiteSetting.max_post_length = 150000

        validate_users
        validate_topics
        validate_posts
        
        generate_report
    end

    def validate_users
        puts "", "Validating users..."
        last_user_id = -1
        
        total_users = mysql_query("SELECT COUNT(*) count FROM #{TABLE_PREFIX}core_members").first["count"]
        @report[:users][:total] = total_users

        batches(BATCH_SIZE) do |offset|
            users = mysql_query(<<~SQL).to_a
                SELECT member_id AS id, name, email
                FROM #{TABLE_PREFIX}core_members
                WHERE member_id > #{last_user_id}
                ORDER BY member_id
                LIMIT #{BATCH_SIZE}
            SQL

            break if users.empty?
            last_user_id = users.last["id"]

            users.each do |u|
                # Force UTF-8 processing mapping
                u.each do |k, v|
                    if v.is_a?(String)
                        v.force_encoding("UTF-8")
                        v.encode!("UTF-8", invalid: :replace, undef: :replace, replace: "") unless v.valid_encoding?
                    end
                end

                username = u["name"].to_s.strip
                email = u["email"].to_s.strip

                # Create a temporary user to test Discourse validations
                temp_user = User.new(
                    username: username,
                    email: email,
                    name: username
                )

                if temp_user.valid?
                    @report[:users][:valid] += 1
                else
                    @report[:users][:invalid] += 1
                    
                    # Tally the specific error categories
                    temp_user.errors.messages.each do |field, messages|
                        messages.each do |msg|
                            error_key = "#{field}: #{msg}"
                            @report[:users][:errors][error_key] += 1
                        end
                    end
                end
            end
            
            print "\rValidated #{offset + users.size} / #{total_users} users..."
        end
        puts ""
    end

    def validate_topics
        puts "", "Validating topics..."
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
        @report[:topics][:total] = total_topics

        batches(BATCH_SIZE) do |offset|
            topics = mysql_query(<<~SQL).to_a
                SELECT t.tid AS id, t.starter_id
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

            topics.each do |t|
                # In dry run, we don't have the newly created users, 
                # so we check if the original source ID exists in IPS database
                user_exists = mysql_query("SELECT 1 FROM #{TABLE_PREFIX}core_members WHERE member_id = #{t["starter_id"]}").to_a.any?
                if !user_exists && t["starter_id"].to_i > 0
                    @report[:topics][:missing_users] += 1
                end
            end
            print "\rValidated #{offset + topics.size} / #{total_topics} topics..."
        end
        puts ""
    end

    def validate_posts
        puts "", "Validating posts..."
        last_post_id = -1
        
        total_posts = mysql_query(<<~SQL).first["count"]
            SELECT COUNT(*) AS count
            FROM #{TABLE_PREFIX}forums_posts
            WHERE new_topic = 0 AND pdelete_time = 0 AND queued = 0
        SQL
        @report[:posts][:total] = total_posts

        batches(BATCH_SIZE) do |offset|
            posts = mysql_query(<<~SQL).to_a
                SELECT pid AS id, author_id, topic_id
                FROM #{TABLE_PREFIX}forums_posts
                WHERE new_topic = 0 AND pdelete_time = 0 AND queued = 0
                AND pid > #{last_post_id}
                ORDER BY pid
                LIMIT #{BATCH_SIZE}
            SQL

            break if posts.empty?
            last_post_id = posts[-1]["id"]

            posts.each do |p|
                user_exists = mysql_query("SELECT 1 FROM #{TABLE_PREFIX}core_members WHERE member_id = #{p["author_id"]}").to_a.any?
                if !user_exists && p["author_id"].to_i > 0
                    @report[:posts][:missing_users] += 1
                end
                
                topic_exists = mysql_query("SELECT 1 FROM #{TABLE_PREFIX}forums_topics WHERE tid = #{p["topic_id"]}").to_a.any?
                if !topic_exists
                    @report[:posts][:missing_topics] += 1
                end
            end
            print "\rValidated #{offset + posts.size} / #{total_posts} posts..."
        end
        puts ""
    end

    def generate_report
        puts "\n"
        puts "============================================="
        puts "         DRY RUN VALIDATION REPORT           "
        puts "============================================="
        
        puts "\n[ USERS ]"
        puts "Total Users to Import: #{@report[:users][:total]}"
        puts "Valid Users (Ready):   #{@report[:users][:valid]}"
        puts "Invalid Users:         #{@report[:users][:invalid]}"
        
        if @report[:users][:errors].any?
            puts "\nUser Validation Breakdown:"
            @report[:users][:errors].sort_by { |_, count| -count }.each do |error, count|
                puts "  - #{error} (#{count} users)"
            end
        end

        puts "\n[ TOPICS ]"
        puts "Total Topics to Import: #{@report[:topics][:total]}"
        puts "Topics with Missing/Deleted Authors: #{@report[:topics][:missing_users]}"

        puts "\n[ POSTS ]"
        puts "Total Posts to Import: #{@report[:posts][:total]}"
        puts "Posts with Missing/Deleted Authors: #{@report[:posts][:missing_users]}"
        puts "Posts for Missing/Deleted Topics (Orphans): #{@report[:posts][:missing_topics]}"
        
        puts "\n============================================="
        
        File.write("dry_run_report.json", JSON.pretty_generate(@report))
        puts "Detailed report saved to: dry_run_report.json"
    end

    # Utility method required by architecture but unused in dry run mapping
    def mysql_query(sql)
        @client.query(sql, cache_rows: true)
    end
end

ImportScripts::IPBoard4DryRun.new.execute
