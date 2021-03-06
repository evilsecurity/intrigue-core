
class BaseTask
  include Sidekiq::Worker
  include TaskHelper

  def self.inherited(base)
    TaskFactory.register(base)
  end

  def perform(task_id, entity, options=[], handler_type, hook_uri )

    # We need a way to skip the actual setup,run,cleanup of the task if
    # the caller gave us broken input. We still want to get a result
    # back to the caller though. Assume it's good, and check input along
    # the way.
    broken_input = false

    ###################
    # Create a Logger #
    ###################
    @task_log = TaskLog.new(task_id, self.metadata[:task_name], false)

    #
    # Do a little logging. Do it for the kids.
    #
    @task_log.log "Id: #{task_id}"
    @task_log.log "Entity: #{entity}"

    ###################
    # Sanity Checking #
    ###################

    # XXX - should we sanity check hook_uri here? probably.
    allowed_types = self.metadata[:allowed_types]

    unless entity
      @task_log.error "ERROR! No entity!!!"
      broken_input = true
    end

    # Check to make sure this task can receive an entity of this type
    unless allowed_types.include?(entity["type"]) || allowed_types.include?("*")
      #raise "ERROR! Can't call #{self.metadata[:name]} on entity: #{entity}"
      @task_log.error "Unable to call #{self.metadata[:name]} on entity: #{entity}"
      broken_input = true
    end

    ###########################
    # Perform the actual task #
    ###########################
    @result = {}
    @result[:task_name] = metadata[:name]
    @result[:entity] = entity
    @result[:timestamp_start] = Time.now.getutc
    @result[:entities] = []
    @result[:id] = task_id

    unless broken_input
      # Setup creates the following objects:
      # @entity - the entity we're operating on
      # @user_options - a hash of task options
      # @result - the final result to be passed back to the caller
      @task_log.log "Calling Setup"
      if setup(task_id, entity, options)
        # Call run(), which will use _create_entity
        # to fill out the @result[:entities] array
        begin
          Timeout.timeout($intrigue_global_timeout) do # 15 minutes should be enough time to hit a class b for a single port w/ masscan
            @task_log.log "Calling Run"
            run # run the tas
            @result[:entities].uniq! # Clean up the resulting entities
          end
        rescue Timeout::Error
          @task_log.error "ERROR! Timed out"
        end

      else
        @task_log.error "Setup failed, bailing out!"
      end
    end

    # Grab the task log & html escape before posting
    @task_log.good "Ship it!"
    @result[:task_log] = @task_log.to_text  #Rack::Utils.escape_html(@task_log.to_text) # This is already done at display time, so no need to double up

    # Grab the task log & html escape before posting
    # http://stackoverflow.com/questions/178704/are-unix-timestamps-the-best-way-to-store-timestamps
    @result[:timestamp_end] = Time.now.getutc

    ######################################
    # Send the result back to the caller #
    ######################################
    #
    # @result is a hash that contains these parts:
    #
    #  {"task_name"=>"dns_forward_lookup",
    #   "entity"=>{"type"=>"DnsRecord", "attributes"=>{"name"=>"www.google.com}
    #   "entities"=>[{"type"=>"IpAddress", "attributes"=>{"name"=>"74.125.239.144"}},
    #                {"type"=>"IpAddress", "attributes"=>{"name"=>"74.125.239.148"}},
    #                {"type"=>"IpAddress", "attributes"=>{"name"=>"74.125.239.147"}},
    #                {"type"=>"IpAddress", "attributes"=>{"name"=>"74.125.239.145"}},
    #                {"type"=>"IpAddress", "attributes"=>{"name"=>"74.125.239.146"}},
    #                {"type"=>"Ipv6Address", "attributes"=>{"name"=>"2607:F8B0:4005:802::1014"}}],
    #   "id"=>"7000cc9b-4e66-4814-a4b8-00a1917a79e7",
    #   "timestamp_start" => "2014-12-15 12:00:35 UTC",
    #   "timestamp_end" => "2014-12-15 12:00:35 UTC"
    #   "task_log" => "..."
    #  }
    #

    ###
    ### XXX - Send the results to a webhook
    ###
    if handler_type == "webhook"

      unless hook_uri
        @tasklog.error "FATAL! Webhook URI not specified"
        return
      end

      begin
        #
        # Post the result back to /receive
        #
        @task_log.log "Sending to Webhook: #{hook_uri}" # < task log has already been shipped so this won't show in the task log, only overall logs
        recoded_string = @result.to_json.encode('UTF-8', :invalid => :replace, :replace => '?')
        RestClient.post hook_uri, recoded_string, :content_type => "application/json"

      rescue Encoding::UndefinedConversionError
        # < task log has already been shipped so this won't show in the task log, only overall logs
        @task_log.error "ERROR! Encoding error when converting #{@result} to JSON"
        @task_log.error "Error Character: #{$!.error_char.dump}"
        @task_log.error "Error Character Encoding: #{$!.error_char.encoding}"

      rescue JSON::GeneratorError => e
        # < task log has already been shipped so this won't show in the task log, only overall logs
        @task_log.error "ERROR! Unable to post results to #{hook_uri}"
        @task_log.error  "#{e.class}: #{e}"

      rescue Exception => e
        # < task log has already been shipped so this won't show in the task log, only overall logs
        @task_log.error "ERROR! Unable to post results to #{hook_uri}"
        @task_log.error  "#{e.class}: #{e}"

      end

    ###
    ### XXX - Write the results to a file
    ###
    elsif handler_type == "file"

      ###
      ### THIS IS A HACK TO GENERATE A FILENAME ... think this through a bit more
      ###

      shortname = "#{metadata[:name]}-#{_get_entity_attribute("name").gsub("/","")}"

      filepath = "#{$intrigue_basedir}/results/#{shortname}.json"

      @task_log.log "Writing to file: #{filepath}" # < task log has already been shipped so this won't show in the task log, only overall logs

      f = File.open(filepath,"w+")
      f.write(JSON.pretty_generate(JSON.parse(@result.to_json)))
      f.close

=begin
    elsif handler_type == "csv"

      File.open("#{$intrigue_basedir}/results/results.csv", File::RDWR) do |f|
        file.flock(File::LOCK_EX)

        # Create outstring
        outstring = "#{result[:task_name]},#{result[:entity]},#{result[:task_log]}"

        # Write file here.
        f.write(outstring)

      end
=end

    end

    # Run Cleanup
    @task_log.log "Calling cleanup()"
    cleanup unless broken_input
  end

  #########################################################
  # These methods are used to perform work in several steps.
  # they should be overridden by individual tasks, but note that
  # individual tasks must always call super()
  #
  def setup(task_id, entity, user_options)

    # XXX - we should do some sanity checking on this entity
    # because it's coming directly from the user - at least
    # verify that it's a real object
    #
    @entity = entity

    # We need to parse options and make sure we're
    # allowed to accept these options. Compare to allowed_options.

    ###
    ### XXX SECURITY - needs gating on options (use the regex values)
    ###

    ###
    ### XXX move all option processing up here, so it happens in one place
    ###     vs having it scattered around throughout the module (_get_option)
    ###

    #
    # allowed options is formatted:
    #    [{:name => "count", :type => "Integer", :default => 1 }, ... ]
    #
    # user_options is formatted:
    #    [{"name" => "option name", "value" => "value"}, ...]
    allowed_options = self.metadata[:allowed_options]

    @user_options = []

    if user_options

      #@task_log.log "Got user options #{user_options}"

      # for each of the user-supplied options
      user_options.each do |user_option| # should be an array of hashes

        #@task_log.log "User option #{user_option}"

        # go through the allowed options
        allowed_options.each do |allowed_option|

          #@task_log.log "Allowed option #{allowed_option}"

          # if we have a match
          if "#{user_option["name"]}" == "#{allowed_option[:name]}"

            #@task_log.log "Got allowed option: #{user_option["name"]}"

            ###
            ### Match the user option against it's specified regex
            ###

            #@task_log.log "Allowed option: #{allowed_option}"

            # XXX - we need to regex the option in order to accept it
            if allowed_option[:regex] == "integer"
              @task_log.log "Regex should match an integer"
              regex = /^\d+$/
            elsif allowed_option[:regex] == "boolean"
              @task_log.log "Regex should match a boolean"
              regex = /(true|false)/
            elsif allowed_option[:regex] == "alpha_numeric"
              @task_log.log "Regex should match an alpha-numeric string"
              regex = /^[a-zA-Z0-9_]*$/
            elsif allowed_option[:regex] == "alpha_numeric_list"
              @task_log.log "Regex should match an alpha-numeric list"
              regex = /^[a-zA-Z0-9_,\?\.\-]*$/
            elsif allowed_option[:regex] == "filename"
              @task_log.log "Regex should match a filename"
              regex = /(?:\..*(?!\/))+/
            elsif allowed_option[:regex] == "ip_address"
              @task_log.log "Regex should match an IP Address"
              regex = /^(\s*((([0-9A-Fa-f]{1,4}:){7}([0-9A-Fa-f]{1,4}|:))|(([0-9A-Fa-f]{1,4}:){6}(:[0-9A-Fa-f]{1,4}|((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3})|:))|(([0-9A-Fa-f]{1,4}:){5}(((:[0-9A-Fa-f]{1,4}){1,2})|:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3})|:))|(([0-9A-Fa-f]{1,4}:){4}(((:[0-9A-Fa-f]{1,4}){1,3})|((:[0-9A-Fa-f]{1,4})?:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(([0-9A-Fa-f]{1,4}:){3}(((:[0-9A-Fa-f]{1,4}){1,4})|((:[0-9A-Fa-f]{1,4}){0,2}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(([0-9A-Fa-f]{1,4}:){2}(((:[0-9A-Fa-f]{1,4}){1,5})|((:[0-9A-Fa-f]{1,4}){0,3}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(([0-9A-Fa-f]{1,4}:){1}(((:[0-9A-Fa-f]{1,4}){1,6})|((:[0-9A-Fa-f]{1,4}){0,4}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(:(((:[0-9A-Fa-f]{1,4}){1,7})|((:[0-9A-Fa-f]{1,4}){0,5}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:)))(%.+)?\s*)|((\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3}))$/
            else
              @task_log.error "Unspecified regex for this option #{allowed_option[:name]}"
              @task_log.error "FATAL! Unable to continue!"
              return nil
            end

            # Run the regex
            unless user_option["value"].match regex
              @task_log.error "Regex didn't match"
              @task_log.error "Option #{user_option["name"]} does not match regex: #{regex.to_s} (#{user_option["value"]})!"
              @task_log.error "FATAL! No task processing since regex didn't match option!"
              return nil
            end

            ###
            ### End Regex matching
            ###

            # We have an allowed option, with the right kind of value
            # ...Now set the correct type

            # So basically, things like core-cli are parsing data as strings, and are sending us
            # all of our options as strings. Which sucks. We have to do the explicit conversion
            # to the right type if we want things to go smoothly. I'm sure there's a better
            # way to do this in ruby, but i equally sure don't know what it is. We'll raise
            # a FATAL if there's something we can't handle

            if allowed_option[:type] == "Integer"
              # convert to integer
              #@task_log.log "Converting #{user_option["name"]} to an integer"
              user_option["value"] = user_option["value"].to_i
            elsif allowed_option[:type] == "String"
              # do nothing, we can just pass strings through
              #@task_log.log "No need to convert #{user_option["name"]} to a string"
              user_option["value"] = user_option["value"]
            elsif allowed_option[:type] == "Boolean"
              # use our monkeypatched .to_bool method (see initializers)
              #@task_log.log "Converting #{user_option["name"]} to a bool"
              user_option["value"] = user_option["value"].to_bool
            else
              # throw an error, we likely have a string we don't know how to cast
              @task_log.error "FATAL! Don't know how to handle this option when it's given to us as a string."
              return nil
            end

            # hurray, we can accept this value
            #@task_log.good "Allowed user_option! #{user_option}"
            @user_options << { allowed_option[:name] => user_option["value"] }
          end
        end

      end
      @task_log.log "Task configured with the following options: #{@user_options}"
    else
      @task_log.log "No User options"
    end
  true
  end

  def run()
  end

  def cleanup()
    @task_log = nil
    @entity = nil
    @user_options = nil
    @result = nil
  end
  #
  #########################################################

  private

    # Convenience Method to execute a system command semi-safely
    #  !!!! Don't send anything to this without first whitelisting user input!!!
    def _unsafe_system(command)

      ###                  ###
      ###  XXX - SECURITY  ###
      ###                  ###

      if command =~ /(\||\;|\`)/
        #raise "Illegal character"
        @task_log.error "FATAL Illegal character in #{command}"
        return
      end

      `#{command}`
    end

    ###
    ### XXX TODO - move this up into the setup method
    ###
    def _get_option(name)

      # Start with nothing
      value = nil

      # First, get the default value by cycling through the allowed options
      method = metadata[:allowed_options].each do |allowed_option|
        value = allowed_option[:default] if allowed_option[:name] == name
      end

      # Then, cycle through the user-provided options
      @user_options.each do |user_option|
        value = user_option[name] if user_option[name]
      end

      #@task_log.log "Option configured: #{name}"

    value
    end

    #
    # This is a helper method, use this to create entities from within tasks
    #
    def _create_entity(type, attributes)
      @task_log.good "Creating entity: #{type}, #{attributes.inspect}"

      # Create the entity, validating the attributes
      entity = EntityFactory.create_by_type(type,attributes)

      # If we don't get anything back, safe to assume we can't move on
      unless entity
        @task_log.error "SKIPPING Unable to verify entity: #{type} #{attributes}"
        return
      end

      # Add to our result set for this task
      @result[:entities] << entity.to_json

    # return the entity
    entity
    end

    def _canonical_name
      "#{self.metadata[:name]}: #{self.metadata[:version]}"
    end

    def _get_entity_attribute(name)
      "#{@entity["attributes"][name]}"
    end


end
