### NEEDED for new gem launch

### [ ] judo does not work with ruby 1.8.6 - :(
### [ ] saw a timeout on volume allocation - make sure we build in re-tries - need to allocate the server all together as much as possible
### [ ] there is a feature to allow for using that block_mapping feature - faster startup

### [ ] return right away.. (1 hr)
### [ ] two phase delete (1 hr)
### [-] refactor availability_zone (2 hrs)
###     [ ] pick availability zone from config "X":"Y" or  "X":["Y","Z"]
###     [ ] assign to state on creation ( could delay till volume creation )
### [ ] implement auto security_group creation and setup (6 hrs)
### [ ] write some examples - simple postgres/redis/couchdb server (5hrs)
### [ ] write new README (4 hrs)
### [ ] bind kuzushi gem version version
### [ ] realase new gem! (1 hr)

### [ ] should be able to do ALL actions except commit without the repo!
### [ ] store git commit hash with commit to block a judo commit if there is newer material stored
### [ ] remove the tarball - store files a sha hashes in the bucket - makes for faster commits if the files have not changed

### [ ] use a logger service (1 hr)
### [ ] write specs (5 hr)

### Error Handling
### [ ] no availability zone before making disks
### [ ] security group does not exists

### Do Later
### [ ] use amazon's new conditional write tools so we never have problems from concurrent updates
### [ ] is thor really what we want to use here?
### [ ] need to be able to pin a config to a version of kuzushi - gem updates can/will break a lot of things
### [ ] I want a "judo monitor" command that will make start servers if they go down, and poke a listed port to make sure a service is listening, would be cool if it also detects wrong ami, wrong secuirity group, missing/extra volumes, missing/extra elastic_ip - might not want to force a reboot quite yet in these cases
### [ ] Implement "judo snapshot [NAME]" to take a snapshot of the ebs's blocks
### [ ] ruby 1.9.1 support
### [ ] find a good way to set the hostname or prompt to :name
### [ ] remove fog/s3 dependancy
### [ ] enforce template files end in .erb to make room for other possible templates as defined by the extensions
### [ ] zerigo integration for automatic DNS setup
### [ ] How cool would it be if this was all reimplemented in eventmachine and could start lots of boxes in parallel?  Would need to evented AWS api calls... Never seen a library to do that - would have to write our own... "Fog Machine?"

module Judo
  class Server
    attr_accessor :name

    def initialize(base, name, group)
      @base = base
      @name = name
      @group_name = group
    end

    def create
      raise JudoError, "no group specified" unless @group_name

      if @name.nil?
        index = @base.servers.map { |s| (s.name =~ /^#{s.group.name}.(\d*)$/); $1.to_i }.sort.last.to_i + 1
        @name = "#{group.name}.#{index}"
      end

      raise JudoError, "there is already a server named #{name}" if @base.servers.detect { |s| s.name == @name and s != self}

      task("Creating server #{name}") do
        update "name" => name, "group" => @group_name, "virgin" => true, "secret" => rand(2 ** 128).to_s(36)
        @base.sdb.put_attributes("judo_config", "groups", @group_name => name)
      end

      allocate_resources

      self
    end

    def group
      @group ||= @base.groups.detect { |g| g.name == @group_name }
    end

    def fetch_state
      @base.sdb.get_attributes(self.class.domain, name)[:attributes]
    end

    def state
      @base.servers_state[name] ||= fetch_state
    end

    def get(key)
      state[key] && [state[key]].flatten.first
    end

    def instance_id
      get "instance_id"
    end

    def elastic_ip
      get "elastic_ip"
    end

    def size_desc
      if not running? or ec2_instance_type == instance_size
        instance_size
      else
        "#{ec2_instance_type}/#{instance_size}"
      end
    end

    def version_desc
      return "" unless running?
      if version == group.version
        "v#{version}"
      else
        "v#{version}/#{group.version}"
      end
    end

    def version
      get("version").to_i
    end

    def virgin?
      get("virgin").to_s == "true"  ## I'm going to set it to true and it will come back from the db as "true" -> could be "false" or false or nil also
    end

    def secret
      get "secret"
    end

    def volumes
      Hash[ (state["volumes"] || []).map { |a| a.split(":") } ]
    end

    def self.domain
      "judo_servers"
    end

    def update(attrs)
      @base.sdb.put_attributes(self.class.domain, name, attrs, :replace)
      state.merge! attrs
    end

    def add(key, value)
      @base.sdb.put_attributes(self.class.domain, name, { key => value })
      (state[key] ||= []) << value
    end

    def remove(key, value = nil)
      if value
        @base.sdb.delete_attributes(self.class.domain, name, key => value)
        state[key] - [value]
      else
        @base.sdb.delete_attributes(self.class.domain, name, [ key ])
        state.delete(key)
      end
    end

    def delete
      group.delete_server(self)
      @base.sdb.delete_attributes(self.class.domain, name)
    end

######## end simple DB access  #######

    def instance_size
      config["instance_size"]
    end

    def config
      group.config
    end

    def to_s
      "#{name}:#{@group_name}"
    end

    def allocate_resources
      if config["volumes"]
        [config["volumes"]].flatten.each do |volume_config|
          device = volume_config["device"]
          if volume_config["media"] == "ebs"
            size = volume_config["size"]
            if not volumes[device]
              task("Creating EC2 Volume #{device} #{size}") do
                ### EC2 create_volume
                volume_id = @base.ec2.create_volume(nil, size, config["availability_zone"])[:aws_id]
                add_volume(volume_id, device)
              end
            else
              puts "Volume #{device} already exists."
            end
          else
            puts "device #{device || volume_config["mount"]} is not of media type 'ebs', skipping..."
          end
        end
      end

      begin
        if config["elastic_ip"] and not elastic_ip
          ### EC2 allocate_address
          task("Adding an elastic ip") do
            ip = @base.ec2.allocate_address
            add_ip(ip)
          end
        end
      rescue Aws::AwsError => e
        if e.message =~ /AddressLimitExceeded/
          invalid "Failed to allocate ip address: Limit Exceeded"
        else
          raise
        end
      end
    end

    def task(msg, &block)
      @base.task(msg, &block)
    end

    def self.task(msg, &block)
      printf "---> %-24s ", "#{msg}..."
      STDOUT.flush
      start = Time.now
      result = block.call
      result = "done" unless result.is_a? String
      finish = Time.now
      time = sprintf("%0.1f", finish - start)
      puts "#{result} (#{time}s)"
      result
    end

    def has_ip?
      !!elastic_ip
    end

    def has_volumes?
      not volumes.empty?
    end

    def ec2_volumes
      return [] if volumes.empty?
      @base.ec2.describe_volumes( volumes.values )
    end

    def remove_ip
      @base.ec2.release_address(elastic_ip) rescue nil
      remove "elastic_ip"
    end

    def destroy
      stop if running?
      ### EC2 release_address
      task("Deleting Elastic Ip") { remove_ip } if has_ip?
      volumes.each { |dev,v| remove_volume(v,dev) }
      task("Destroying server #{name}") { delete }
    end

    def ec2_state
      ec2_instance[:aws_state] rescue "offline"
    end

    def ec2_instance
      ### EC2 describe_instances
      @base.ec2_instances.detect { |e| e[:aws_instance_id] == instance_id } or {}
    end

    def running?
      ## other options are "terminated" and "nil"
      ["pending", "running", "shutting_down", "degraded"].include?(ec2_state)
    end

    def start
      invalid "Already running" if running?
      invalid "No config has been commited yet, type 'judo commit'" unless group.version > 0
      task("Starting server #{name}")      { launch_ec2 }
      task("Wait for server")              { wait_for_running } if elastic_ip or has_volumes?
      task("Attaching ip")                 { attach_ip } if elastic_ip
      task("Attaching volumes")            { attach_volumes } if has_volumes?
    end

    def restart
      stop if running?
      start
    end

    def generic_name?
      name =~ /^#{group}[.]\d*$/
    end

    def generic?
      volumes.empty? and not has_ip? and generic_name?
    end

    def invalid(str)
      raise JudoInvalid, str
    end

    def stop
      invalid "not running" unless running?
      ## EC2 terminate_isntaces
      task("Terminating instance") { @base.ec2.terminate_instances([ instance_id ]) }
      task("Wait for volumes to detach") { wait_for_volumes_detached } if volumes.size > 0
      remove "instance_id"
    end

    def launch_ec2
#      validate

      ## EC2 launch_instances
      ud = user_data
      debug(ud)
      result = @base.ec2.launch_instances(ami,
        :instance_type => config["instance_size"],
        :availability_zone => config["availability_zone"],
        :key_name => config["key_name"],
        :group_ids => security_groups,
        :user_data => ud).first

      update "instance_id" => result[:aws_instance_id], "virgin" => false, "version" => group.version
    end

    def debug(str)
      return unless ENV['JUDO_DEBUG'] == "1"
      puts "<JUDO_DEBUG>#{str}</JUDO_DEBUG>"
    end

    def security_groups
      [ config["security_group"] ].flatten
    end

    def console_output
      invalid "not running" unless running?
      @base.ec2.get_console_output(instance_id)[:aws_output]
    end

    def ami
      ia32? ? config["ami32"] : config["ami64"]
    end

    def ia32?
      ["m1.small", "c1.medium"].include?(instance_size)
    end

    def ia64?
      not ia32?
    end

    def hostname
      ec2_instance[:dns_name] == "" ? nil : ec2_instance[:dns_name]
    end

    def wait_for_running
      loop do
        return if ec2_state == "running"
        reload
        sleep 1
      end
    end

    def wait_for_hostname
      loop do
        reload
        return hostname if hostname
        sleep 1
      end
    end

    def wait_for_volumes_detached
      ## FIXME - force if it takes too long
      loop do
        break if ec2_volumes.reject { |v| v[:aws_status] == "available" }.empty?
        sleep 2
      end
    end

    def wait_for_termination
      loop do
        reload
        break if ec2_instance[:aws_state] == "terminated"
        sleep 1
      end
    end

    def wait_for_ssh
      invalid "not running" unless running?
      loop do
        begin
          reload
          Timeout::timeout(4) do
            TCPSocket.new(hostname, 22)
            return
          end
        rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH
        end
      end
    end

    def add_ip(public_ip)
      update "elastic_ip" => public_ip
      attach_ip
    end

    def attach_ip
      return unless running? and elastic_ip
      ### EC2 associate_address
      @base.ec2.associate_address(instance_id, elastic_ip)
    end

    def dns_name
      return nil unless elastic_ip
      `dig +short -x #{elastic_ip}`.strip
    end

    def attach_volumes
      return unless running?
      volumes.each do |device,volume_id|
        ### EC2 attach_volume
        @base.ec2.attach_volume(volume_id, instance_id, device)
      end
    end

    def remove_volume(volume_id, device)
      task("Deleting #{device} #{volume_id}") do
        ### EC2 delete_volume
        @base.ec2.delete_volume(volume_id)
        remove "volumes", "#{device}:#{volume_id}"
      end
    end

    def add_volume(volume_id, device)
      invalid("Server already has a volume on that device") if volumes[device]

      add "volumes", "#{device}:#{volume_id}"

      @base.ec2.attach_volume(volume_id, instance_id, device) if running?

      volume_id
    end

    def connect_ssh
      wait_for_ssh
      system "chmod 600 #{group.keypair_file}"
      system "ssh -i #{group.keypair_file} #{config["user"]}@#{hostname}"
    end

    def self.commit
      ## FIXME
      Config.group_dirs.each do |group_dir|
        group = File.basename(group_dir)
        next if Config.group and Config.group != group
        puts "commiting #{group}"
        doc = Config.couchdb.get(group) rescue {}
        config = Config.read_config(group)
        config['_id'] = group
        config['_rev'] = doc['_rev'] if doc.has_key?('_rev')
        response = Config.couchdb.save_doc(config)
        doc = Config.couchdb.get(response['id'])

        # walk subdirs and save as _attachments
        ['files', 'templates', 'packages', 'scripts'].each { |subdir|
          Dir["#{group_dir}/#{subdir}/*"].each do |f|
            puts "storing attachment #{f}"
            doc.put_attachment("#{subdir}/#{File.basename(f)}", File.read(f))
          end
        }
      end
    end

    def ec2_instance_type
      ec2_instance[:aws_instance_type] rescue nil
    end

    def ip
      hostname || config["state_ip"]
    end

    def reload
      @base.reload_ec2_instances
      @base.servers_state.delete(name)
    end

    def user_data
      <<USER_DATA
#!/bin/sh

export DEBIAN_FRONTEND="noninteractive"
export DEBIAN_PRIORITY="critical"
export SECRET='#{secret}'
apt-get update
apt-get install ruby rubygems ruby-dev irb libopenssl-ruby libreadline-ruby -y
gem install kuzushi --no-rdoc --no-ri
GEM_BIN=`ruby -r rubygems -e "puts Gem.bindir"`
echo "$GEM_BIN/kuzushi #{virgin? && "init" || "start"} '#{url}'" > /var/log/kuzushi.log
$GEM_BIN/kuzushi #{virgin? && "init" || "start"} '#{url}' >> /var/log/kuzushi.log 2>&1
USER_DATA
    end

    def url
      @url ||= group.s3_url
    end

    def validate
      ### EC2 create_security_group
      @base.create_security_group

      ### EC2 desctibe_key_pairs
      k = @base.ec2.describe_key_pairs.detect { |kp| kp[:aws_key_name] == config["key_name"] }

      if k.nil?
        if config["key_name"] == "judo"
          @base.create_keypair
        else
          raise "cannot use key_pair #{config["key_name"]} b/c it does not exist"
        end
      end
    end

    def <=>(s)
      [group.name, name] <=> [s.group.name, s.name]
    end

  end
end
