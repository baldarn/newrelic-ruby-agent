# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/newrelic-ruby-agent/blob/main/LICENSE for complete details.
# frozen_string_literal: true

require 'fileutils'

module Multiverse
  module Runner
    extend self
    extend Color

    def exit_status
      @exit_status ||= 0
    end

    def notice_exit_status(i)
      exit_status # initialize it
      # we don't want to return exit statuses > 256 since these get converted
      # to 0
      if i != 0
        puts red("FAIL! Exited #{i}")
        @exit_status = 1
      else
        puts green("PASS. Exited #{i}")
      end
      @exit_status
    end

    # Args without a = are turned into just opts[key] = true
    # Args with = get split, then assigned as key + value. Repeats overwrite
    # Args with name= will tally up rather than overwriting
    # :suite gets ignored
    def parse_args(args)
      opts = {}
      args.each do |(k, v)|
        if v.index("name=") == 0
          parts = v.split("=")
          opts[:names] ||= []
          opts[:names] << parts.last
        elsif v.include?("=")
          parts = v.split("=")
          opts[parts.first.to_sym] = parts.last
        elsif k != :suite
          opts[v.to_sym] = true
        end
      end
      opts
    end

    def run(filter = "", opts = {})
      # This file is generated by TestTimeReporter.
      # TestTimeReporter cannot be loaded until minitest has been loaded by an
      # individual suite, so we cannot define this inside the TestTimeReporter
      # class. Please keep this path and the paths for the reporter constants
      # the same!
      FileUtils.rm_f(Multiverse::TEST_TIME_REPORT_PATH)

      execute_suites(filter, opts) do |suite|
        puts yellow(suite.execution_message)
        suite.each_instrumentation_method do |method|
          if opts.key?(:method) && method != opts[:method] && suite.instrumentation_permutations.length > 1
            puts "Skipping method '#{method}' while focusing only on '#{opts[:method]}'" unless ENV["MIN_TEST_OUTPUT"]
            next
          end
          suite.execute(method)
        end
      end
    end

    def prime(filter = "", opts = {})
      execute_suites(filter, opts) do |suite|
        suite.prime
      end
    end

    def execute_suites(filter, opts)
      Dir.new(SUITES_DIRECTORY).entries.each do |dir|
        full_path = File.join(SUITES_DIRECTORY, dir)

        next if dir.start_with?('.')
        next unless passes_filter?(dir, filter)
        next unless File.exist?(File.join(full_path, "Envfile"))

        begin
          suite = Suite.new(full_path, opts)
          yield(suite)
        rescue => e
          puts red("Error when trying to run suite in #{full_path.inspect}")
          puts
          puts "#{e.class}: #{e}"
          puts(*e.backtrace)
          notice_exit_status(1)
        end
      end

      OutputCollector.overall_report
      exit(exit_status)
    end

    GROUPS = {
      "agent" => %w[agent_only bare config_file_loading deferred_instrumentation high_security no_json json marshalling yajl],
      "background" => %w[delayed_job sidekiq resque],
      "background_2" => ["rake"],
      "database" => %w[datamapper elasticsearch mongo redis sequel],
      "rails" => %w[active_record active_record_pg rails rails_prepend activemerchant],
      "frameworks" => %w[sinatra padrino grape],
      "httpclients" => %w[curb excon httpclient],
      "httpclients_2" => %w[typhoeus net_http httprb],
      "infinite_tracing" => ["infinite_tracing"],

      "rest" => [] # Specially handled below
    }

    # Would like to reinstate but requires investigation, see RUBY-1749
    if RUBY_VERSION < '2.3'
      GROUPS['background_2'].delete('rake')
    end

    if RUBY_PLATFORM == "java"
      GROUPS['agent'].delete('agent_only')
    end

    if RUBY_VERSION >= '3.0'
      # this suite uses mysql2 which has issues on ruby 3.0+
      # a new suite, active_record_pg, has been added to run active record tests on ruby 3.0+
      GROUPS['rails'].delete('active_record')
    end

    def excluded?(suite)
      return true if suite == 'rake' and RUBY_VERSION < '2.3'
      return true if suite == 'agent_only' and RUBY_PLATFORM == "java"
      return true if suite == 'active_record' and RUBY_VERSION >= '3.0.0'
    end

    def passes_filter?(dir, filter)
      return true if filter.nil?

      return false if excluded?(dir)

      if filter.include?("group=")
        keys = filter.sub("group=", "").split(';') # supports multiple groups passed in ";" delimited
        combined_groups = []

        # grabs all the suites that are in each of the groups passed in
        keys.each do |key|
          (combined_groups << (GROUPS[key])).flatten!
        end

        # checks for malformed groups passed in
        if combined_groups.nil?
          puts red("Unrecognized groups in '#{filter}'. Stopping!")
          exit(1)
        end

        # This allows the "rest" group to be passed in as one of several groups that are ';' delimited
        # true IF
        # the "rest" group is one of the groups being passed in AND the directory is not in any other group
        # OR
        # the directory is one of the suites included in one of the non-rest groups passed in
        (keys.include?("rest") && !GROUPS.values.flatten.include?(dir)) || (combined_groups.any? && combined_groups.include?(dir))
      else
        dir.eql?(filter)
      end
    end
  end
end
