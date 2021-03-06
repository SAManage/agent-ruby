# Copyright 2015 EPAM Systems
#
#
# This file is part of Report Portal.
#
# Report Portal is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# ReportPortal is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with Report Portal.  If not, see <http://www.gnu.org/licenses/>.

require 'securerandom'
require 'tree'
require 'rspec/core'
require 'fileutils'
require_relative '../../reportportal'

module ReportPortal
  module RSpec
    class Formatter
      MAX_DESCRIPTION_LENGTH = 255
      MIN_DESCRIPTION_LENGTH = 3

      ::RSpec::Core::Formatters.register self, :dump_summary, :start

      def initialize(_output)
        ENV['REPORT_PORTAL_USED'] = 'true'
      end

      def start(_start_notification)
        # ReportPortal.start_launch('OMRI-TEST-111')
        @root_node = Tree::TreeNode.new(SecureRandom.hex)
        @current_group_node = @root_node
      end

      def dump_summary(notification)
        return unless should_report?(notification)  # Report to RP only if no failures OR if rerun
        example_group_started(notification.examples.first.example_group, notification.examples.first)
        notification.examples.each do |example|
          example_started(example)
          end_time = example.execution_result.finished_at
          case example.execution_result.status
          when :passed
            example_passed(example, end_time)
          when :failed
            example_failed(example, end_time)
          when :pending
            example_pending(example, end_time)
          end
        end
        example_group_finished(notification.examples.first.example_group)
        # stop(nil)
      end

      def example_group_started(group_notification, first_example)
        description = group_notification.description
        description = "#{description} (SUBSET = #{ENV['SUBSET']})" if ENV['SUBSET']
        description += " (SEQUENTAIL)" if ENV['SEQ']
        description += " (ACCOUNT = #{ENV['ACCOUNT_NAME']})" if ENV['ACCOUNT_NAME']
        description += " (USER = #{ENV['USER_TYPE']})" if ENV['USER_TYPE']
        description += " (LABS - #{ENV['LABS']})" if ENV['LABS']
        description += " (RERUN)" if ENV['RERUN']
        if description.size < MIN_DESCRIPTION_LENGTH
          p "Group description should be at least #{MIN_DESCRIPTION_LENGTH} characters ('group_notification': #{group_notification.inspect})"
          return
        end
        tags = []
        item = ReportPortal::TestItem.new(description[0..MAX_DESCRIPTION_LENGTH-1],
                                          :TEST,
                                          nil,
                                          format_start_time(first_example),
                                          '',
                                          false,
                                          tags,
                                          false)
        group_node = Tree::TreeNode.new(SecureRandom.hex, item)
        if group_node.nil?
          p "Group node is nil for item #{item.inspect}"
        else
          @current_group_node << group_node unless @current_group_node.nil? # make @current_group_node parent of group_node
          @current_group_node = group_node
          group_node.content.id = ReportPortal.start_item(group_node)
        end
      end

      def example_group_finished(_group_notification)
        unless @current_group_node.nil?
          ReportPortal.finish_item(@current_group_node.content)
          @current_group_node = @current_group_node.parent
        end
      end

      def example_started(notification)
        is_rerun = !ENV['RERUN'].nil?
        description = notification.description
        if description.size < MIN_DESCRIPTION_LENGTH
          p "Example description should be at least #{MIN_DESCRIPTION_LENGTH} characters ('notification': #{notification.inspect})"
          return
        end

        ReportPortal.current_scenario = ReportPortal::TestItem.new(description[0..MAX_DESCRIPTION_LENGTH-1],
                                                                   :STEP,
                                                                   nil,
                                                                   format_start_time(notification),
                                                                   '',
                                                                   false,
                                                                   [],
                                                                   is_rerun)
        example_node = Tree::TreeNode.new(SecureRandom.hex, ReportPortal.current_scenario)
        if example_node.nil?
          p "Example node is nil for scenario #{ReportPortal.current_scenario.inspect}"
        else
          @current_group_node << example_node
          example_node.content.id = ReportPortal.start_item(example_node)
        end
      end

      def example_passed(notification, end_time = nil)
        upload_example_data(:passed, notification) if ENV['RERUN']
        ReportPortal.finish_item(ReportPortal.current_scenario, :passed, end_time) unless ReportPortal.current_scenario.nil?
        ReportPortal.current_scenario = nil
      end

      def example_failed(notification, end_time = nil)
        upload_example_data(:failed, notification)
        unless ReportPortal.current_scenario.nil?
          ReportPortal.finish_item(ReportPortal.current_scenario, :failed, end_time)
        end
        ReportPortal.current_scenario = nil
      end

      def upload_example_data(state, notification)
        puts '^ ^ ^ ^ ^ ^  START SCREENSHOT UPLOAD!  ^ ^ ^ ^ ^ ^'
        upload_screenshots(notification)
        puts '^ ^ ^ ^ ^ ^  END SCREENSHOT UPLOAD!  ^ ^ ^ ^ ^ ^'
        log_content = read_log_file_content(notification)
        ReportPortal.send_log(state, log_content, ReportPortal.now)
      end

      def example_pending(notification, end_time = nil)
        unless ReportPortal.current_scenario.nil?
          pending_msg = notification.execution_result.pending_message
          ReportPortal.finish_item(ReportPortal.current_scenario, :skipped, end_time, nil, pending_msg)
        end
        ReportPortal.current_scenario = nil
      end

      def message(notification)
        if notification.message.respond_to?(:read)
          ReportPortal.send_file(:passed, notification.message)
        else
          ReportPortal.send_log(:passed, notification.message, ReportPortal.now)
        end
      end

      def stop(_notification)
        # ReportPortal.finish_launch
      end

      private

      def read_log_file_content(example)
        exception = example.exception
        base_log = exception ? "#{exception.class}: #{exception.message}\n\nBacktrace: #{exception.backtrace.join("\n")}" : ''
        if example.file_path.match('(\w+).rb')
          file_name = $1
          file_name = "#{file_name}_#{ENV['SUBSET']}" unless ENV['SUBSET'].nil?
          log_content = read_log_content(file_name)
          output = "#{base_log}\n\n\n####### Full Log #######\n\n"
          output += "######## Rerun Log #######\n\n#{log_content[:rerun_log]}\n\n" if log_content[:rerun_log]
          output +="######## First Run Log #######\n\n#{log_content[:run_log]}\n\n" if log_content[:run_log]
          output
        else
          "example file name did not match [#{example.file_name}]\n\n#{base_log}"
        end
      rescue => e
        puts "read_log_file_content failed\n Error: #{e}"
      end

      def read_log_content(file_name)
        run_log = "./log/#{file_name}.log"
        rerun_log = "./log/#{file_name}_rerun.log"
        logs = {}
        logs[:run_log] = IO.read(run_log) if File.exist?(run_log)
        logs[:rerun_log] = IO.read(rerun_log) if File.exist?(rerun_log)
        puts "No log files found!!!\nExpected one of these:\n1: #{run_log}\n2: #{rerun_log}" if logs.size.eql?(0)
        logs
      end

      def upload_screenshots(notification)
        return unless notification.metadata[:screenshot]

        notification.metadata[:screenshot].each do |img|
          file_name = "./log/#{img}.png"
          new_file_name = "./log/#{SecureRandom.uuid}.png"
          FileUtils.cp(file_name, new_file_name)
          ReportPortal.send_file(:failed, new_file_name, img, ReportPortal.now, 'image/png')
          File.delete(new_file_name)
        end
      end

      def format_start_time(example)
        example.execution_result.started_at
      end

      def should_report?(notification)
        failed = read_failures_count(notification)
        file_name = notification.examples.first.file_path
        viz_test = !file_name.match(/visualization|viz/).nil?
        is_rerun = !ENV['RERUN'].nil? || viz_test
        should_report = failed.zero? || is_rerun
        puts "[RP] Should Report? ==> #{should_report} | Failed = #{failed} | RERUN = #{is_rerun}"
        should_report
      end

      def read_failures_count(notification)
        notification.examples.select { |example| example.execution_result.status == :failed }.count
      end
    end
  end
end
