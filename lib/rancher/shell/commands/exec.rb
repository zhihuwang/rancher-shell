require 'rancher/shell/api'
require 'rancher/shell/logger_helper'
require 'rancher/shell/websocket_client'

module Rancher
  module Shell
    module Commands
      class Exec
        include LoggerHelper

        attr_reader :api, :websocket

        def initialize
          @config = Config.get_all
          logger.debug "config = #{@config}"
          exit_with_error "Project not found: #{@config['project']}" unless @config['project']
          exit_with_error "Command not specified" unless @config['options']['command'] && @config['options']['command'] != ''
          exit_with_error "Container not specified" unless @config['options']['container'] && @config['options']['container'] != ''
          exit_with_error "API Host Required" unless @config['project']['api'] && @config['project']['api']['host']
          exit_with_error "API Key Required" unless @config['project']['api'] && @config['project']['api']['key']
          exit_with_error "API Secret Required" unless @config['project']['api'] && @config['project']['api']['secret']
        end

        def listen!
          begin
            logger.info "listening"
            system("stty raw")
            while input = STDIN.getc
              @websocket.send Base64.encode64 input
            end
          ensure
            system("stty -raw echo")
          end
        end

        def setup_api!
          @api = Rancher::Shell::Api.new(
            host: @config['project']['api']['host'],
            user: @config['project']['api']['key'],
            pass: @config['project']['api']['secret'],
          )
        end

        def retrieve_containers!
          @response = @api.get(
            "containers",
          )
          @containers = @response.json['data'].map do |container|
            {
              'id' => container['id'],
              'name' => container['name'],
              'state' => container['state'],
              'ports' => container['ports'],
            }
          end
          @container = @containers.find { |container| container['name'] === @config['options']['container'] }
          exit_with_error "could not find container: #{@config['options']['container']}" unless @container
        end

        def setup_websocket!
          logger.info "container = #{@container['id']}"
          # default_bash_command = "TERM=xterm-256color; export TERM; [ -x /bin/bash ] && ([ -x /usr/bin/script ] && /usr/bin/script -q -c \"/bin/bash\" /dev/null || exec /bin/bash) || exec /bin/sh"
          # @config['options']['command'] = default_bash_command if @config['options']['command'] === 'bash'
          logger.debug "running command: #{@config['options']['command']}"
          @response = @api.post(
            "containers/#{@container['id']}?action=execute",
            "command" => [
              "/bin/sh",
              "-c",
              @config['options']['command'],
            ],
            "attachStdin" => true,
            "attachStdout" => true,
            "tty" => true,
          )
          websocket_url = "#{@response.json['url']}?token=#{@response.json['token']}"
          logger.info "connecting to #{@response.json['url']} ..."
          @websocket = Rancher::Shell::WebsocketClient.new websocket_url, headers: { 'Authorization' => "Bearer #{@response.json['token']}"}
          @websocket.on :open do |event|
            logger.info "  connected!"
          end
          @websocket.on :chunk do |encoded_chunk|
            chunk = Base64.decode64 encoded_chunk
            emit :message, chunk
          end
          @websocket.on :message do |data|
            $stdout.print data
          end
          @websocket.on :error do |event|
            logger.error "socket error: #{event}"
            Kernel.exit true
          end
          @websocket.on :close do
            logger.error "closed connection"
            Kernel.exit true
          end
        end
      end
    end
  end
end
