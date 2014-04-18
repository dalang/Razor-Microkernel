# Manages the vmodel process (used by the rz_mk_control_server to
# communicate with the Razor server on request)
#
#

require 'rubygems'
require 'yaml'
require 'razor_microkernel/logging'
require 'razor_microkernel/rz_mk_configuration_manager'
require 'razor_microkernel/rz_mk_fact_manager'
require 'singleton'
require 'open4'
require 'net/http'
require 'fileutils'

# set up a global variable that will be used in the RazorMicrokernel::Logging mixin
# to determine where to place the log messages from this script (will be combined
# with the other log messages for the Razor Microkernel Controller)
RZ_MK_LOG_PATH = "/var/log/rz_mk_controller.log" unless defined? RZ_MK_LOG_PATH

module RazorMicrokernel
  class RzMkVmodelManager
    include Singleton

    # include the RazorMicrokernel::Logging mixin (which enables logging)
    include RazorMicrokernel::Logging

    MK_VMODEL_PATH = '/tmp/'
    DEF_MK_VMODEL_URI = "http://localhost:2156/vmodel"
    # file used to track baremetal state in vmodel process
    VMODEL_CHECKIN_STATE_FILENAME = "/tmp/vmodel_checkin.yaml"
    attr_accessor :hw_id
    attr_accessor :emantsoh

    def send_request_to_server(method, action)
      unless @hw_id
        logger.error "hw_id is empty!"
      else
        config_manager = (RazorMicrokernel::RzMkConfigurationManager).instance
        vmodel_uri = config_manager.mk_uri + config_manager.mk_vmodel_path
        uri = URI "#{vmodel_uri}/#{method}/#{action}?hw_id=#{@hw_id}"
        response = Net::HTTP.get(uri)
        logger.debug "vmodel response => #{response}"
        response
      end
    end


    def get_file_from_server(method, file_name)
      unless @hw_id
        logger.error "hw_id is empty!"
      else
        config_manager = (RazorMicrokernel::RzMkConfigurationManager).instance
        vmodel_uri = config_manager.mk_uri + config_manager.mk_vmodel_path
        unless file_name.index('.')
          uri = URI "#{vmodel_uri}/#{method}/file?hw_id=#{@hw_id}&name=#{file_name}"
        else
          uri = URI "#{vmodel_uri}/#{method}/file?hw_id=#{@hw_id}&name=#{file_name.match(/(.*)\..*/)[1]}"
        end

        response = Net::HTTP.get(uri)
        logger.debug "vmodel response => #{response}"
        save_vmodel_file(file_name, response)
      end
    end


    def save_vmodel_file(file_name, data)
      logger.debug "Saving VModel file: #{file_name}"
      File.open("#{MK_VMODEL_PATH}/#{file_name}", 'w') { |file| file.write(data) }
    end


    def do_baking(mode, files, cicode)
      current_state = 'idle'
      case mode
      when "solo"
        logger.info 'Baking in SOLO mode.'
        current_state = phase_start('baking', 'true', files, cicode)
      when "skip"
        current_state = phase_start('baking', 'false', files, cicode)
      when "do"
        current_state = phase_start('baking', 'true', files, cicode)
      else
        logger.error "baking model should be one of [solo, skip, do]."
      end
      current_state
    end


    def phase_start (name, enabled, files, cicode)
      current_state = 'idle'

      unless get_vmodel_checkin(name) == 'running'
        logger.debug "file is empty!" unless files
        current_state = name
        unless @log_file
          timestamp = %x[date +%Y%m%d%H%M]
          config_manager = (RazorMicrokernel::RzMkConfigurationManager).instance
          FileUtils::mkdir_p "#{config_manager.mk_hw_log_path}/#{@emantsoh}"
          @log_file = "#{config_manager.mk_hw_log_path}/#{@emantsoh}/#{timestamp.chop}.log"
        end
        if enabled == 'false'
          logger.info "skip #{name} setting"
          send_request_to_server name, 'skip'
          set_vmodel_checkin!(name, 'skip')
          current_state = 'idle'
        else
          logger.info "start #{name} setting"
          send_request_to_server name, 'start'
          files.each { |file_name| get_file_from_server name, file_name }
          set_vmodel_checkin!(name, 'running')
          # run phase setting in background
          run_script_background(files.first, name)
        end
      end

      current_state
    end


    def phase_end(name)
      if get_vmodel_checkin(name) == 'running'
        logger.info "complete #{name} setting."
        set_vmodel_checkin!(name, 'done')
        return "#{name} setting completed"
      end
      return "#{name} setting is not running"
    end


    def run_script_background(filename, phase)
      if File.exist?("/tmp/#{filename}")
        logger.info "run script #{filename} in background"

        background_job = fork do
          status = Open4::popen4("sh /tmp/#{filename}") do |pid, stdin, stdout, stderr|
            #%x(echo "#{stdin.read.strip}" >> #{@log_file})
            %x(echo "#{stdout.read.strip}" >> #{@log_file})
            %x(echo "#{stderr.read.strip}" >> #{@log_file})
          end
          if status.exitstatus == 0
            uri = URI "#{DEF_MK_VMODEL_URI}?phase=#{phase}"
            begin
              response = Net::HTTP.get(uri)
              logger.debug "send notify to change phase status to 'done': #{response}"
            rescue EOFError
              logger.error "vmodel http get error"
            end
          else
            %x(echo "#{status.exitstatus}" >> #{@log_file})
          end
        end
        Process.detach(background_job)
      else
        logger.error "can not find file: [#{filename}] in /tmp"
      end
    end


    # get/set api for vmodel_checkin.yaml
    def set_vmodel_checkin!(key, value)
      logger.info "set_vmodel_checkin #{key}, #{value}"
      return unless File.exists?(VMODEL_CHECKIN_STATE_FILENAME)

      vmodel_state = YAML::load(File.open(VMODEL_CHECKIN_STATE_FILENAME))
      vmodel_state[key] = value unless vmodel_state.fetch(key, 'none') == 'none'
      File.open(VMODEL_CHECKIN_STATE_FILENAME, 'w') { |file| YAML.dump(vmodel_state, file) }
    end


    def get_vmodel_checkin(key)
      return 'none' unless File.exists?(VMODEL_CHECKIN_STATE_FILENAME)
      vmodel_state = YAML::load(File.open(VMODEL_CHECKIN_STATE_FILENAME))
      ret = vmodel_state.fetch(key, 'none')
      logger.info "get_vmodel_checkin #{ret}"
      ret
    end


    def reset_vmodel_state
      # reset vmodel_checkin.yaml
      data = YAML::load(File.open(VMODEL_CHECKIN_STATE_FILENAME))
      data.each_key { |k| data[k] = nil }
      File.open(VMODEL_CHECKIN_STATE_FILENAME, 'w') { |file| YAML.dump(data, file) }
      @log_file = nil
    end

  end
end
