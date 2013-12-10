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

# set up a global variable that will be used in the RazorMicrokernel::Logging mixin
# to determine where to place the log messages from this script (will be combined
# with the other log messages for the Razor Microkernel Controller)
RZ_MK_LOG_PATH = "/var/log/rz_mk_controller.log"

module RazorMicrokernel
  class RzMkVmodelManager
    include Singleton

    # include the RazorMicrokernel::Logging mixin (which enables logging)
    include RazorMicrokernel::Logging

    MK_VMODEL_PATH = '/tmp/'
    DEF_MK_VMODEL_URI = "http://localhost:2158/vmodel"
    # file used to track baremetal state in vmodel process
    VMODEL_CHECKIN_STATE_FILENAME = "/tmp/vmodel_checkin.yaml"
    attr_accessor :firmware
    attr_accessor :baking
    attr_accessor :bmc
    attr_accessor :raid
    attr_accessor :bios
    attr_accessor :hw_id

    def initialize
      @firmware = false
      @baking = false
      @bmc = false
      @raid = false
      @bios = false
      @hw_id = nil
      @log_file = nil
    end

    def send_request_to_server(method, action)
      unless @hw_id
        logger.error "hw_id is empty!"
      else
        config_manager = (RazorMicrokernel::RzMkConfigurationManager).instance
        vmodel_uri = config_manager.mk_uri + config_manager.mk_vmodel_path
        uri = URI "#{vmodel_uri}/#{method}/#{action}?hw_id=#{@hw_id}"
        logger.info "http uri: #{uri.to_s}"
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
        logger.info "http uri: #{uri.to_s}"

        response = Net::HTTP.get(uri)
        save_vmodel_file(file_name, response)
      end
    end

    def save_vmodel_file(file_name, data)
      logger.debug "Saving VModel file: #{file_name}"
      File.open("#{MK_VMODEL_PATH}/#{file_name}", 'w') { |file|
        file.write(data)
      }
    end

    def update_firmware(enabled, files, cicode)
      unless @firmware
        current_state = 'firmware'
        logger.debug "file is empty!" unless files
        if enabled == 'false'
          logger.info "Skip firmware updating"
          send_request_to_server 'firmware', 'skip'
          set_vmodel_checkin!('firmware', 'skip')
          current_state = 'idle'
        else
          send_request_to_server 'firmware', 'start'
          files.each do |file_name|
            get_file_from_server 'firmware', file_name
          end
          unless @log_file
            timestamp = %x[date +%Y%m%d-%H%M%S]
            config_manager = (RazorMicrokernel::RzMkConfigurationManager).instance
            @log_file = "#{config_manager.mk_hw_log_path}/#{cicode}-#{timestamp.chop}.log"
          end
          # run firmware scripts in background
          set_vmodel_checkin!('firmware', 'running')
          #system "bash /tmp/hpsum.sh >> #{@log_file} &"
          logger.info "sudo sh /tmp/#{files.first} >> #{@log_file} &"
          system "sudo sh /tmp/#{files.first} >> #{@log_file} &"
        end
        @firmware = true
      end
      current_state
    end

    def set_bmc(enabled, files, cicode)
      unless @bmc
        current_state = 'bmc'
        logger.debug "file is empty!" unless files
        if enabled == 'false'
          logger.info "Skip bmc/ilo setting"
          send_request_to_server 'bmc', 'skip'
          set_vmodel_checkin!('bmc', 'skip')
          current_state = 'idle'
        else
          send_request_to_server 'bmc', 'start'
          files.each do |file_name|
            get_file_from_server 'bmc', file_name
          end
          unless @log_file
            timestamp = %x[date +%Y%m%d-%H%M%S]
            config_manager = (RazorMicrokernel::RzMkConfigurationManager).instance
            @log_file = "#{config_manager.mk_hw_log_path}/#{cicode}-#{timestamp.chop}.log"
          end
          # run ilo setting in background
          set_vmodel_checkin!('bmc', 'running')
          #system "bash /tmp/iloconf.sh >> #{@log_file} &"
          logger.info "sudo sh /tmp/#{files.first} >> #{@log_file} &"
          system "sudo sh /tmp/#{files.first} >> #{@log_file} &"
        end
        @bmc = true
      end
      current_state
    end

    def do_baking(mode, files, cicode)
      unless @baking
        current_state = 'baking'
        logger.debug "file is empty!" unless files
        if mode == 'skip'
          logger.info "Skip baking"
          send_request_to_server 'baking', 'skip'
          set_vmodel_checkin!('baking', 'skip')
          current_state = 'idle'
        elsif mode == 'solo'
          logger.info 'baking only'
          send_request_to_server 'baking', 'start'
          files.each do |file_name|
            get_file_from_server 'baking', file_name
          end
          unless @log_file
            timestamp = %x[date +%Y%m%d-%H%M%S]
            config_manager = (RazorMicrokernel::RzMkConfigurationManager).instance
            @log_file = "#{config_manager.mk_hw_log_path}/#{cicode}-#{timestamp.chop}.log"
          end
          # run baking in background
          set_vmodel_checkin!('baking', 'running_only')
          #system "bash /tmp/svrdiags2d.sh >> #{@log_file} &"
          logger.info "sudo sh /tmp/#{files.first} >> #{@log_file} &"
          system "sudo sh /tmp/#{files.first} >> #{@log_file} &"
        else # mode == 'do'
          logger.info 'baking normally'
          send_request_to_server 'baking', 'start'
          files.each do |file_name|
            get_file_from_server 'baking', file_name
          end
          unless @log_file
            timestamp = %x[date +%Y%m%d-%H%M%S]
            config_manager = (RazorMicrokernel::RzMkConfigurationManager).instance
            @log_file = "#{config_manager.mk_hw_log_path}/#{cicode}-#{timestamp.chop}.log"
          end
          # run baking in background
          set_vmodel_checkin!('baking', 'running')
          #system "bash /tmp/svrdiags2d.sh >> #{@log_file} &"
          logger.info "sudo sh /tmp/#{files.first} >> #{@log_file} &"
          system "sudo sh /tmp/#{files.first} >> #{@log_file} &"
        end
        @baking = true
      end
      current_state
    end

    def set_raid(enabled, files, cicode)
      unless @raid
        logger.debug "file is empty!" unless files
        current_state = 'raid'
        if enabled == 'false'
          logger.info "Skip raid setting"
          send_request_to_server 'raid', 'skip'
          set_vmodel_checkin!('raid', 'skip')
          current_state = 'idle'
        else
          send_request_to_server 'raid', 'start'
          files.each do |file_name|
            get_file_from_server 'raid', file_name
          end
          unless @log_file
            timestamp = %x[date +%Y%m%d-%H%M%S]
            config_manager = (RazorMicrokernel::RzMkConfigurationManager).instance
            @log_file = "#{config_manager.mk_hw_log_path}/#{cicode}-#{timestamp.chop}.log"
          end
          # run raid setting in background
          set_vmodel_checkin!('raid', 'running')
          #system "bash /tmp/raidconf.sh >> #{@log_file} &"
          logger.info "sudo sh /tmp/#{files.first} >> #{@log_file} &"
          system "sudo sh /tmp/#{files.first} >> #{@log_file} &"
        end
        @raid = true
      end
      current_state
    end

    def set_bios(enabled, files, cicode)
      unless @bios
        logger.debug "file is empty!" unless files
        current_state = 'bios'
        if enabled == 'false'
          logger.info "Skip bios setting"
          send_request_to_server 'bios', 'skip'
          set_vmodel_checkin!('bios', 'skip')
          current_state = 'idle'
        else
          send_request_to_server 'bios', 'start'
          files.each do |file_name|
            get_file_from_server 'bios', file_name
          end
          unless @log_file
            timestamp = %x[date +%Y%m%d-%H%M%S]
            config_manager = (RazorMicrokernel::RzMkConfigurationManager).instance
            @log_file = "#{config_manager.mk_hw_log_path}/#{cicode}-#{timestamp.chop}.log"
          end
          # run bios setting in background
          set_vmodel_checkin!('bios', 'running')
          #system "bash /tmp/biosconf.sh >> #{@log_file} &"
          logger.info "sudo sh /tmp/#{files.first} >> #{@log_file} &"
          system "sudo sh /tmp/#{files.first} >> #{@log_file} &"
        end
        @bios = true
      end
      current_state
    end

    def firmware_done
      if get_vmodel_checkin('firmware') == 'running'
        #send_request_to_server 'firmware', 'end'
        set_vmodel_checkin!('firmware', 'done')
        return 'firmware updating done accepted'
      end
      return 'firmware updating is not running'
    end

    def baking_done
      logger.debug "baking: #{get_vmodel_checkin('baking')}"
      if get_vmodel_checkin('baking') == 'running'
        #send_request_to_server 'baking', 'end'
        set_vmodel_checkin!('baking', 'done')
        return 'baking done accepted'
      end
      if get_vmodel_checkin('baking') == 'running_solo'
        #send_request_to_server 'baking', 'solo'
        set_vmodel_checkin!('baking', 'done_solo')
        return 'baking in solo mode done accepted'
      end
      return 'baking is not running'
    end

    def bios_done
      if get_vmodel_checkin('bios') == 'running'
        #send_request_to_server 'bios', 'end'
        set_vmodel_checkin!('bios', 'done')
        return 'bios setting done accepted'
      end
      return 'bios setting is not running'
    end

    def raid_done
      if get_vmodel_checkin('raid') == 'running'
        #send_request_to_server 'raid', 'end'
        set_vmodel_checkin!('raid', 'done')
        return 'raid setting done accepted'
      end
      return 'raid setting is not running'
    end

    def bmc_done
      if get_vmodel_checkin('bmc') == 'running'
        #send_request_to_server 'bmc', 'end'
        set_vmodel_checkin!('bmc', 'done')
        return 'bmc/ilo setting done accepted'
      end
      return 'bmc/ilo setting is not running'
    end

    # get/set api for vmodel_checkin.yaml
    def set_vmodel_checkin!(key, value)
      logger.info "set_vmodel_checkin #{key}, #{value}"
      return unless File.exists?(VMODEL_CHECKIN_STATE_FILENAME)
      vmodel_state = YAML::load(File.open(VMODEL_CHECKIN_STATE_FILENAME))
      vmodel_state[key] = value unless vmodel_state.fetch(key, 'none') == 'none'
      File.open(VMODEL_CHECKIN_STATE_FILENAME, 'w') { |file| YAML.dump(vmodel_state, file)
      }
    end

    def get_vmodel_checkin(key)
      return 'none' unless File.exists?(VMODEL_CHECKIN_STATE_FILENAME)
      vmodel_state = YAML::load(File.open(VMODEL_CHECKIN_STATE_FILENAME))
      ret = vmodel_state.fetch(key, 'none')
      logger.info "get_vmodel_checkin #{ret}"
      ret
    end

  end
end
