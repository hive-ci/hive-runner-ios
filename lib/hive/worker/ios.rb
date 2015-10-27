require 'hive/worker'
require 'hive/messages/ios_job'
require 'fruity_builder'

module Hive
  class PortReserver
    attr_accessor :ports
    def initialize
      self.ports = {}
    end

    def reserve(queue_name)
      self.ports[queue_name] = yield
      self.ports[queue_name]
    end
  end

  class Worker
    class Ios < Worker

      attr_accessor :device

      def initialize(device)
        @worker_ports = PortReserver.new
        self.device = device
        super(device)
      end

      def alter_project(project_path)
        dev_team              = @options['development_team']      || ''
        signing_identity      = @options['signing_identity']      || ''
        provisioning_profile  = @options['provisioning_profile']  || ''

        helper = FruityBuilder::IOS::Helper.new(project_path)

        helper.build.replace_bundle_id(@options['bundle_id'])

        helper.build.replace_dev_team(dev_team)
        helper.build.replace_code_sign_identity(signing_identity)
        helper.build.replace_provisioning_profile(provisioning_profile)
        helper.build.save_project_properties
      end

      def replace_project_data(options = {})
        regex = Regexp.new(options[:regex])
        replacements = options[:data].scan(regex).uniq.flatten

        result = options[:data]
        replacements.each do |to_replace|
          result = result.gsub(to_replace, options[:new_value])
        end

        result
      end

      def pre_script(job, file_system, script)
        Hive.devicedb('Device').poll(@options['id'], 'busy')

        if job.build
          FileUtils.mkdir(file_system.home_path + '/build')
          app_path = file_system.home_path + '/build/' + 'build.ipa'

          file_system.fetch_build(job.build, app_path)
          app_info = DeviceAPI::IOS::Plistutil.get_bundle_id_from_app(app_path)
          app_bundle = app_info['CFBundleIdentifier']
          script.set_env 'BUNDLE_ID', app_bundle
        else
          alter_project(file_system.home_path + '/test_code/code/')
        end

        ip_address = DeviceAPI::IOS::IPAddress.address(self.device['serial'])

        script.set_env 'CHARLES_PROXY_PORT',  @ports.reserve(queue_name: 'Charles')

        # TODO: Allow the scheduler to specify the ports to use

        script.set_env 'APPIUM_PORT',         @worker_ports.reserve(queue_name: 'Appium') { self.allocate_port }
        script.set_env 'BOOTSTRAP_PORT',      @worker_ports.reserve(queue_name: 'Bootstrap') { self.allocate_port }
        script.set_env 'CHROMEDRIVER_PORT',   @worker_ports.reserve(queue_name: 'Chromedriver') { self.allocate_port }

        script.set_env 'APP_PATH', app_path
        script.set_env 'APP_BUNDLE_PATH', app_path
        script.set_env 'DEVICE_TARGET', self.device['serial']
        script.set_env 'DEVICE_ENDPOINT', "http://#{ip_address}:37265"

        "#{self.device['serial']} #{@ports.ports['Appium']} #{app_path} #{file_system.results_path}"
      end

      def job_message_klass
        Hive::Messages::IosJob
      end

      def post_script(job, file_system, script)
        @log.info('Post script')
        @worker_ports.ports.each do |name, port|
          self.release_port(port)
        end
        set_device_status('idle')
      end

      def device_status
        details = Hive.devicedb('Device').find(@options['id'])
        if details.key?('status')
          @state = details['status']
        else
          @state
        end
      end

      def set_device_status(status)
        @state = status
        begin
          details = Hive.devicedb('Device').poll(@options['id'], status)
          if details.key?('status')
            @state = details['status']
          else
            @state
          end
        rescue
          @state
        end
      end
    end
  end
end