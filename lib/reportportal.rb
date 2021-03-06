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

require 'json'
require 'rest_client'
require 'uri'
require 'pathname'
require 'tempfile'

require_relative 'report_portal/settings'
require_relative 'report_portal/patches/rest_client'

LAUNCH_ID = 'rp_launch_id'
LAUNCH_NUMBER = 'rp_launch_number'
JSON_ID = 'id'
JSON_NUMBER = 'number'

module ReportPortal
  TestItem = Struct.new(:name, :type, :id, :start_time, :description, :closed, :tags, :retry)
  LOG_LEVELS = { error: 'ERROR', warn: 'WARN', info: 'INFO', debug: 'DEBUG', trace: 'TRACE', fatal: 'FATAL', unknown: 'UNKNOWN' }

  @response_handler = proc do |response, request, result, &block|
    if (200..207).include? response.code
      response
    else
      p "ReportPortal API returned #{response}"
      p "Offending request method/URL: #{request.args[:method].upcase} #{request.args[:url]}"
      p "Offending request payload: #{request.args[:payload]}}"
      response.return!(request, result, &block)
    end
  end

  class << self
    attr_accessor :current_scenario

    def now
      Time.now
    end

    def status_to_level(status)
      case status
      when :passed
        LOG_LEVELS[:info]
      when :failed, :undefined, :pending, :error
        LOG_LEVELS[:error]
      when :skipped
        LOG_LEVELS[:warn]
      else
        LOG_LEVELS.fetch(status, LOG_LEVELS[:info])
      end
    end

    def launch_id
      p "[RP] Launch ID = #{ENV[LAUNCH_ID]}"
      ENV[LAUNCH_ID]
    end

    def launch_number
      p "[RP] Launch Number = #{ENV[LAUNCH_NUMBER]}"
      ENV[LAUNCH_NUMBER]
    end

    def start_launch(description, start_time = now)
      url = "#{Settings.instance.project_url}/launch"
      data = { name: Settings.instance.launch, start_time: format_time(start_time), tags: Settings.instance.tags, description: description, mode: Settings.instance.launch_mode }
      do_request(url) do |resource|
        res = JSON.parse(resource.post(data.to_json, content_type: :json, &@response_handler))
        ENV[LAUNCH_ID] = res[JSON_ID]
        ENV[LAUNCH_NUMBER] = res[JSON_NUMBER].to_s
      end
    end

    def finish_launch(end_time = now)
      url = "#{Settings.instance.project_url}/launch/#{launch_id}/finish"
      data = { end_time: format_time(end_time) }
      do_request(url) do |resource|
        resource.put data.to_json, content_type: :json, &@response_handler
      end
    end

    def start_item(item_node)
      url = "#{Settings.instance.project_url}/item"
      url += "/#{item_node.parent.content.id}" unless item_node.parent && item_node.parent.is_root?
      p "[RP] Start Item  ==>  #{item_node.content}"
      item = item_node.content
      data = { start_time: format_time(item.start_time), name: item.name[0, 255], type: item.type.to_s, launch_id: launch_id, description: item.description }
      data[:tags] = item.tags unless item.tags.empty?
      do_request(url) do |resource|
        JSON.parse(resource.post(data.to_json, content_type: :json, &@response_handler))['id']
      end
    end

    def finish_item(item, status = nil, end_time = nil, force_issue = nil, pending_message = nil)
      unless item.nil? || item.id.nil? || item.closed
        p "[RP] Finish Item  ==>  (id: #{item.id}"
        url = "#{Settings.instance.project_url}/item/#{item.id}"
        data = { end_time: format_time(end_time.nil? ? now : end_time) }
        data[:status] = status unless status.nil?
        p "[RP] Finish Item  ==>  (id: #{item.id}"
        if force_issue && status != :passed # TODO: check for :passed status is probably not needed
          data[:issue] = { issue_type: 'AUTOMATION_BUG', comment: force_issue.to_s }
        elsif status == :skipped
          data[:tags] = [pending_message] if pending_message
          data[:issue] = { issue_type: 'NOT_ISSUE' }
        end
        do_request(url) do |resource|
          resource.put data.to_json, content_type: :json, &@response_handler
        end
        item.closed = true
      end
    end

    def find_launch(browser, branch, build_number)
      url = "#{Settings.instance.project_url}/launch?filter.eq.number=#{build_number}&filter.eq.name=#{branch}%20-%20#{browser}"
      do_request(url) do |resource|
        data = JSON.parse(resource.get)['content'][0]['id']
      end
    end

    def force_finish(launch_id)
      url = "#{Settings.instance.project_url}/launch/#{launch_id}/stop"
      force_finish_body =
        {
          'description': 'string',
          'end_time': Time.now.utc.iso8601(3),
          'status': 'STOPPED',
          'tags': ['string']
        }
      do_request(url) do |resource|
        resource.put force_finish_body.to_json, content_type: :json, &@response_handler
      end
    end

    def send_log(status, message, time)
      unless @current_scenario.nil? || @current_scenario.closed # it can be nil if scenario outline in expand mode is executed
        url = "#{Settings.instance.project_url}/log"
        data = { item_id: @current_scenario.id, time: format_time(time), level: status_to_level(status), message: message.to_s }
        do_request(url) do |resource|
          resource.post(data.to_json, content_type: :json, &@response_handler)
        end
      end
    end

    def send_file(status, path, label = nil, time = now, mime_type='image/png')
      url = "#{Settings.instance.project_url}/log"
      unless File.file?(path)
        extension = ".#{MIME::Types[mime_type].first.extensions.first}"
        temp = Tempfile.open(['file',extension])
        temp.binmode
        temp.write(Base64.decode64(path))
        temp.rewind
        path = temp
      end
      File.open(File.realpath(path), 'rb') do |file|
        label ||= File.basename(file)
        json = { level: status_to_level(status), message: label, item_id: @current_scenario.id, time: format_time(time), file: { name: File.basename(file) } }
        data = { :json_request_part => [json].to_json, label => file, :multipart => true, :content_type => 'application/json' }
        do_request(url) do |resource|
          resource.post(data, { content_type: 'multipart/form-data' }, &@response_handler)
        end
      end
    end

    # needed for parallel formatter
    def item_id_of(name, parent_node)
      if parent_node.is_root? # folder without parent folder
        url = "#{Settings.instance.project_url}/item?filter.eq.launch=#{launch_id}&filter.eq.name=#{URI.escape(name)}&filter.size.path=0"
      else
        url = "#{Settings.instance.project_url}/item?filter.eq.parent=#{parent_node.content.id}&filter.eq.name=#{URI.escape(name)}"
      end
      do_request(url) do |resource|
        data = JSON.parse(resource.get)
        if data.key? 'content'
          data['content'].empty? ? nil : data['content'][0]['id']
        else
          nil # item isn't started yet
        end
      end
    end

    # needed for parallel formatter
    def close_child_items(parent_id)
      if parent_id.nil?
        url = "#{Settings.instance.project_url}/item?filter.eq.launch=#{launch_id}&filter.size.path=0&page.page=1&page.size=100"
      else
        url = "#{Settings.instance.project_url}/item?filter.eq.parent=#{parent_id}&page.page=1&page.size=100"
      end
      ids = []
      loop do
        response = do_request(url) { |r| JSON.parse(r.get) }
        if response.key?('links')
          link = response['links'].find { |i| i['rel'] == 'next' }
          url = link.nil? ? nil : link['href']
        else
          url = nil
        end
        response['content'].each do |i|
          ids << i['id'] if i['has_childs'] && i['status'] == 'IN_PROGRESS'
        end
        break if url.nil?
      end

      ids.each do |id|
        close_child_items(id)
        # temporary, we actually only need the id
        finish_item(TestItem.new(nil, nil, id, nil, nil, nil, nil))
      end
    end

    private

    def format_time(time)
      time = Time.parse(time) if time.is_a?(String)
      time.strftime("%Y-%m-%dT%H:%M:%S.%L%z")
    end

    def create_resource(url)
      props = { :headers => {:Authorization => "Bearer #{Settings.instance.uuid}"}}
      verify_ssl = Settings.instance.disable_ssl_verification
      props[:verify_ssl] = !verify_ssl unless verify_ssl.nil?
      RestClient::Resource.new url, props
    end

    def do_request(url)
      resource = create_resource(url)
      tries = 3
      begin
        yield resource
      rescue
        p "Request to #{url} produced an exception: #{$!.class}: #{$!}"
        $!.backtrace.each { |l| p l }
        retry unless (tries -= 1).zero?
        p "Failed to execute request to #{url} after 3 attempts."
        nil
      end
    end
  end
end
