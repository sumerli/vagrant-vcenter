require 'vagrant'

module VagrantPlugins
  module VCenter
    # Initialize Provider configuration parameters.
    class Config < Vagrant.plugin('2', :config)
      # login attributes

      # The vCenter  hostname
      #
      # @return [String]
      attr_accessor :hostname

      # The username used to log in
      #
      # @return [String]
      attr_accessor :username

      # The password used to log in
      #
      # @return [String]
      attr_accessor :password

      # WIP on these

      # Catalog Name where the item resides
      #
      # @return [String]
      attr_accessor :folder_name

      # Resource Pool Name where the item will live
      #
      # @return [String]
      attr_accessor :resourcepool_name

      # Catalog Name where the item resides
      #
      # @return [String]
      attr_accessor :template_folder_name

      # Catalog Item to be used as a template
      #
      # @return [String]
      attr_accessor :datastore_name

      # Virtual Data Center to be used
      #
      # @return [String]
      attr_accessor :datacenter_name

      # Virtual Data Center to be used
      #
      # @return [String]
      attr_accessor :computer_name

      # Virtual Data Center Network to be used
      #
      # @return [String]
      attr_accessor :network_name

      # Virtual Data Center Network to be used
      #
      # @return [Bool]
      attr_accessor :linked_clones

      # Disable automatic safe vm name generation
      #
      # @return [Bool]
      attr_accessor :disable_auto_vm_name

      # vm network names
      #
      # @return [String]
      attr_accessor :vm_network_names

      # vm network type
      # only supported network type
      # DistributedVirtualSwitchPort
      #
      # @return [String]
      attr_accessor :vm_network_type

      # Use prep and customization api in the building
      # of the vm in vcenter
      #
      # Mostly this allows the static ip configuration
      # of a vm
      #
      # @return [Bool]
      attr_accessor :enable_vm_customization

      # Type of the machine prep to use
      #
      # @return [String]
      attr_accessor :prep_type

      # Product key to use during Windows customization
      #
      # @return [String]
      attr_accessor :product_key

      # num cpu
      #
      # @return [Fixnum]
      attr_accessor :num_cpu

      # memory in MB
      #
      # @return [Fixnum]
      attr_accessor :memory

      ##
      ## vCenter  config runtime values
      ##

      # connection handle
      attr_accessor :vcenter_cnx
      attr_accessor :template_id

      def initialize
        @prep_type = 'linux'
        @enable_vm_customization = true
      end

      def validate(machine)
        errors = _detected_errors

        # TODO: add blank?
        errors <<
        I18n.t('vagrant_vcenter.config.hostname') if hostname.nil?
        errors <<
        I18n.t('vagrant_vcenter.config.username') if username.nil?
        errors <<
        I18n.t('vagrant_vcenter.config.password') if password.nil?
        errors <<
        I18n.t('vagrant_vcenter.config.datastore_name') if datastore_name.nil?
        errors <<
        I18n.t('vagrant_vcenter.config.datacenter_name') if datacenter_name.nil?
        errors <<
        I18n.t('vagrant_vcenter.config.computer_name') if computer_name.nil?
        errors <<
        I18n.t('vagrant_vcenter.config.network_name') if network_name.nil?
        if enable_vm_customization
          errors <<
          I18n.t('vagrant_vcenter.config.no_prep_type') if prep_type.downcase != 'linux' && prep_type.downcase != 'windows'
        end
        { 'vCenter Provider' => errors }
      end
    end
  end
end
