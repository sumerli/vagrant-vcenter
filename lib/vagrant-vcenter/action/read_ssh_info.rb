module VagrantPlugins
  module VCenter
    module Action
      # This class reads the IP info for the VM that the Vagrant provider is
      # managing using VMware Tools.
      class ReadSSHInfo
        # FIXME: More work needed here for vCenter logic (vApp, VM IPs, etc.)

        def initialize(app, env)
          @app = app
          @logger = Log4r::Logger.new('vagrant_vcenter::action::read_ssh_info')
        end

        def call(env)
          env[:machine_ssh_info] = read_ssh_info(env)

          @app.call env
        end

        def read_ssh_info(env)
          return nil if env[:machine].id.nil?

          config = env[:machine].provider_config
          # FIXME: Raise a correct exception
          dc = config.vcenter_cnx.serviceInstance.find_datacenter(
               config.datacenter_name) or abort 'datacenter not found'
          root_vm_folder = dc.vmFolder
          vm = root_vm_folder.findByUuid(env[:machine].id)

          address = vm.guest.ipAddress

          # return ip address of first nic
          if address
              if config.network_name
                # use network_name as the the main interface
                main_int = config.network_name
              else
                main_int = config.vm_network_names[0]
              end
              @logger.debug("address already found: #{address}")
              for net in vm.guest.net
                if net.network
                    @logger.debug("checking network: #{net.network}")
                    @logger.debug("checking vm network name: #{main_int}")
                    if net.network == main_int
                        @logger.debug("found a match")
                        @logger.debug("number of ip addresses on the interface: #{net.ipConfig.ipAddress.size}")
                        @logger.debug("Setting ip to first nic's ip: #{net.ipConfig.ipAddress}")
                        if !net.ipConfig.ipAddress.empty?
                            address = net.ipConfig.ipAddress[0].ipAddress
                            @logger.debug("Setting ip to first nic's ip: #{address}")
                            break
                        end
                    end
                end
              end
          end

          if not address or address == ''
            address = vm.guest_ip
            if address
                @logger.debug("Setting ip to guest_ip: #{address}")
            end
          end

          if not address or address == ''
            # if we can't find it right away just return nil.  it will retry
            # till the vmware tools supplies the ip address back to vcenter
            @logger.debug('could not find booted guest ipaddress')
            return nil
          end

          @logger.debug("Setting nfs_machine_ip to #{address}")
          env[:nfs_machine_ip] = address

          { :host => address, :port => 22 }
        end
      end
    end
  end
end
