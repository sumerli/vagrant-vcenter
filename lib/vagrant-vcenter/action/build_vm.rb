require 'securerandom'
require 'etc'

module VagrantPlugins
  module VCenter
    module Action
      # This class builds the VM to be used by Vagrant.
      class BuildVM
        def initialize(app, env)
          @app = app
          @logger = Log4r::Logger.new('vagrant_vcenter::action::build_vm')
        end

        def call(env)
          # FIXME: we need to find a way to clean things up when a SIGINT get
          # called... see env[:interrupted] in the vagrant code

          config = env[:machine].provider_config
          vm_name = env[:machine].name

          @logger.debug("config: #{config.pretty_inspect}")

          # FIXME: Raise a correct exception
          dc = config.vcenter_cnx.serviceInstance.find_datacenter(
            config.datacenter_name) or abort 'datacenter not found'

          if env[:machine].box.name.to_s.include? '/'
            box_file = env[:machine].box.name.rpartition('/').last.to_s
            box_name = env[:machine].box.name.to_s.gsub(/\//, '-')
          else
            box_file = env[:machine].box.name.to_s
            box_name = box_file
          end

          if config.template_folder_name.nil?
            box_to_search = box_name
          else
            box_to_search = config.template_folder_name + '/' +
                            box_name
          end

          # FIXME: Raise a correct exception
          computer = dc.find_compute_resource(
                        config.computer_name) or fail 'Host not found'

          if config.resourcepool_name
            rp = computer.resourcePool.resourcePool.find {
              |f| f.name == config.resourcepool_name
            }
          else
            rp = computer.resourcePool
          end

          # FIXME: Raise a correct exception
          template = dc.find_vm(
                        box_to_search) or abort 'VM not found'

          if config.linked_clones
            @logger.debug('DOING LINKED CLONE!')
            # The API for linked clones is quite strange. We can't create a
            # linked straight from any VM. The disks of the VM for which we can
            # create a linked clone need to be read-only and thus VC demands
            # that the VM we are cloning from uses delta-disks. Only then it
            # will allow us to share the base disk.
            #
            # Thus, this code first create a delta disk on top of the base disk
            # for the to-be-cloned VM, if delta disks aren't used already.
            disks = template.config.hardware.device.grep(
                    RbVmomi::VIM::VirtualDisk)
            disks.select { |x| x.backing.parent.nil? }.each do |disk|
              spec = {
                :deviceChange => [
                  {
                    :operation => :remove,
                    :device => disk
                  },
                  {
                    :operation => :add,
                    :fileOperation => :create,
                    :device => disk.dup.tap do |x|
                      x.backing = x.backing.dup
                      x.backing.fileName = "[#{disk.backing.datastore.name}]"
                      x.backing.parent = disk.backing
                    end
                  }
                ]
              }
              template.ReconfigVM_Task(:spec => spec).wait_for_completion
            end

            relocate_spec = RbVmomi::VIM.VirtualMachineRelocateSpec(
                            :diskMoveType => :moveChildMostDiskBacking,
                            :pool => rp)
          else
            relocate_spec = RbVmomi::VIM.VirtualMachineRelocateSpec(
                            :pool => rp)
          end

          @logger.debug("Relocate Spec: #{relocate_spec.pretty_inspect}")

          spec = RbVmomi::VIM.VirtualMachineCloneSpec(
                 :location => relocate_spec,
                 :powerOn => false,
                 :template => false)
          
          if config.vm_network_names or config.num_cpu or config.memory
            config_spec = RbVmomi::VIM.VirtualMachineConfigSpec
            config_spec.numCPUs = config.num_cpu if config.num_cpu
            config_spec.memoryMB = config.memory if config.memory

            if config.vm_network_names
              config_spec.deviceChange = []
              dnic = template.config.hardware.device.grep(RbVmomi::VIM::VirtualEthernetCard).first
              if dnic
                dev_spec = RbVmomi::VIM.VirtualDeviceConfigSpec(:device => dnic, :operation => "remove")
                config_spec.deviceChange << dev_spec
              end

              config.vm_network_names.each do |vm_network_name|
                # First we must find the specified network
                @logger.debug("vm_network_name #{vm_network_name}")
                network = dc.network.find { |f| f.name == vm_network_name } or abort "Could not find network with name #{vm_network_name} to join vm to"
                card = RbVmomi::VIM::VirtualVmxnet3( :key => 0,
                                                     :deviceInfo => {
                                                     :label => vm_network_name,
                                                     :summary => vm_network_name} )
                if config.vm_network_type == "DistributedVirtualSwitchPort"
                  switch_port = RbVmomi::VIM.DistributedVirtualSwitchPortConnection( :switchUuid => network.config.distributedVirtualSwitch.uuid,
                                                                                   :portgroupKey => network.key)
                  card.backing = RbVmomi::VIM.VirtualEthernetCardDistributedVirtualPortBackingInfo(:port => switch_port)
		else
                  card.backing = RbVmomi::VIM::VirtualEthernetCardNetworkBackingInfo(network: network, deviceName: network.name)
                end
                dev_spec = RbVmomi::VIM.VirtualDeviceConfigSpec(:device => card, :operation => "add")
                config_spec.deviceChange << dev_spec
                @logger.debug("config_spec #{config_spec.pretty_inspect}")
              end
            end
            spec.config = config_spec
            @logger.debug("spec.config #{spec.config.pretty_inspect}")
          end

          nic_map = []
          global_ip_settings = []
          if config.enable_vm_customization
            env[:machine].config.vm.networks.each do |type, options|
              if type == :public_network
                @logger.debug("type: #{type.inspect} options: #{options.inspect}")

                # Specify ip but no netmask
                if options[:ip] && !options[:netmask]
                  fail Errors::WrongNetworkSpec
                end

                # specify netmask but no ip
                if !options[:ip] && options[:netmask]
                  fail Errors::WrongNetworkSpec
                end

                global_ip_settings = RbVmomi::VIM.CustomizationGlobalIPSettings(
                      :dnsServerList => options[:dns_server_list],
                      :dnsSuffixList => options[:dns_suffix_list])

                # if no ip and no netmask, let's default to dhcp
                if !options[:ip] && !options[:netmask]
                  adapter = RbVmomi::VIM.CustomizationIPSettings(
                            :ip => RbVmomi::VIM.CustomizationDhcpIpGenerator())
                else
                  adapter = RbVmomi::VIM.CustomizationIPSettings(
                              :gateway => [options[:gateway]],
                              :ip => RbVmomi::VIM.CustomizationFixedIp(
                                  :ipAddress => options[:ip]),
                              :subnetMask => options[:netmask])
                end

                nic_map << RbVmomi::VIM.CustomizationAdapterMapping(
                            :adapter => adapter)
              end
            end

            if config.prep_type.downcase == 'linux'
              prep = RbVmomi::VIM.CustomizationLinuxPrep(
                     :domain => env[:machine].name.to_s.sub(/^[^.]+\./, ''),
                     :hostName => RbVmomi::VIM.CustomizationFixedName(
                                  :name => env[:machine].name.to_s.split('.')[0]))
            elsif config.prep_type.downcase == 'windows'
              if config.product_key.nil?
                product_key = ''
              else
                product_key = config.product_key
              end
              prep = RbVmomi::VIM.CustomizationSysprep(
                      :guiUnattended => RbVmomi::VIM.CustomizationGuiUnattended(
                        :autoLogon => false,
                        :autoLogonCount => 0,
                        :timeZone => 004
                      ),
                      :identification => RbVmomi::VIM.CustomizationIdentification(),
                      :userData => RbVmomi::VIM.CustomizationUserData(
                        :computerName => RbVmomi::VIM.CustomizationFixedName(
                          :name => env[:machine].name.to_s.split('.')[0]),
                        :fullName => 'Vagrant',
                        :orgName => 'Vagrant',
                        :productId => product_key
                  )
              )
            else 
              fail "specification type #{config.prep_type} not supported"
            end

            if prep && nic_map
              # If prep and network specification are present, let's do a full config
              cust_spec = RbVmomi::VIM.CustomizationSpec(
                          :globalIPSettings => global_ip_settings,
                          :identity => prep,
                          :nicSettingMap => nic_map)

              spec.customization = cust_spec

            elsif prep && !nic_map
              # If no network specifications, default to dhcp
              global_ip_settings = RbVmomi::VIM.CustomizationGlobalIPSettings(
                :dnsServerList => [],
                :dnsSuffixList => [])

              adapter = RbVmomi::VIM.CustomizationIPSettings(
                :ip => RbVmomi::VIM.CustomizationDhcpIpGenerator())

              nic_map = [RbVmomi::VIM.CustomizationAdapterMapping(
                 :adapter => adapter)]

              cust_spec = RbVmomi::VIM.CustomizationSpec(
                          :globalIPSettings => global_ip_settings,
                          :identity => prep,
                          :nicSettingMap => nic_map)

              spec.customization = cust_spec
            end

            @logger.debug("Spec: #{spec.pretty_inspect}")
          end

          @logger.debug("disable_auto_vm_name: #{config.disable_auto_vm_name}")

          if config.disable_auto_vm_name || config.disable_auto_vm_name == 'true'
            vm_target = vm_name.to_s
          else
            vm_target = "Vagrant-#{Etc.getlogin}-" +
                        "#{vm_name}-#{Socket.gethostname.downcase}-" +
                        "#{SecureRandom.hex(4)}"
          end

          @logger.debug("VM name: #{vm_target}")

          # FIXME: vm.parent brings us to the template folder, fix this with
          # folder_path.

          root_vm_folder = dc.vmFolder
          vm_folder = root_vm_folder
          unless config.folder_name.nil?
            begin
              # Better ask for forgiveness than permission ;-)
              @logger.debug("Creating folder #{config.folder_name}.")
              vm_folder = root_vm_folder.traverse(config.folder_name,
                                                  RbVmomi::VIM::Folder,
                                                  create = true)
            # FIXME: we should trap the correct exception
            rescue RbVmomi::Fault
              # if somebody else created the folder already...
              @logger.debug("Folder #{config.folder_name} already exists.")
              vm_folder = root_vm_folder.traverse(config.folder_name,
                                                  RbVmomi::VIM::Folder)
            end
          end
          @logger.debug("folder for VM: #{vm_folder}")

          env[:ui].info('Creating VM...')

          template.CloneVM_Task(
                                :folder => vm_folder,
                                :name => vm_target,
                                :spec => spec).wait_for_completion

          if config.folder_name.nil?
            vm_to_search = vm_target
          else
            vm_to_search = config.folder_name + '/' + vm_target
          end

          @logger.debug("VM to search: #{vm_to_search}")

          # FIXME: Raise a correct exception
          env[:machine].id = dc.find_vm(
                            vm_to_search).config.uuid or abort 'VM not found'

          @app.call env
        end
      end
    end
  end
end
