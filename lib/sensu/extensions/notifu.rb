require 'sensu/redis'
require 'sensu/extension'
require 'digest'
require 'json'

module Sensu::Extension
  class Notifu < Handler

    def definition
      {
        type: 'extension',
        name: 'notifu'
      }
    end

    def name
      definition[:name]
    end

    def options
      return @options if @options
      @options = {
        :host    => '127.0.0.1',
        :port    => 6379,
        :db      => 2
      }
      if @settings[:notifu].is_a?(Hash)
        @options.merge!(@settings[:notifu])
      end
      @options
    end

    def description
      'Notifu handler extension for Sensu Server'
    end

    def post_init

      if @redis
        yield(@redis)
      else
        Sensu::Redis.connect(options) do |connection|
          connection.auto_reconnect = false
          connection.reconnect_on_error = true
          connection.on_error do |error|
            @logger.warn(error)
          end
          @redis = connection
        end
      end
      @redis.sadd("queues", "processor")
    end

    def run(event_data)
      event = JSON.parse(event_data, { :symbolize_names => true })
      notifu_id = Digest::SHA256.hexdigest("#{event[:client][:name]}:#{event[:client][:address]}:#{event[:check][:name]}").to_s[-10,10]
      sgs = event[:check][:sgs]
      sgs ||= event[:client][:sgs]

      if @settings[:api][:user] && @settings[:api][:password]
        api_endpoint = "http://#{@settings[:api][:user]}:#{@settings[:api][:password]}@#{@settings[:api][:host].to_s}:#{@settings[:api][:port].to_s}"
      else
        api_endpoint = "http://#{@settings[:api][:host].to_s}:#{@settings[:api][:port].to_s}"
      end

      payload = {
        notifu_id: notifu_id,
        datacenter: event[:client][:datacenter] || 'default',
        host: event[:client][:name],
        address: event[:client][:address],
        service: event[:check][:name],
        occurrences_trigger: event[:check][:occurrences],
        occurrences_count: event[:occurrences],
        interval: event[:check][:interval] || 0,
        time_last_event: event[:check][:executed],
        sgs: sgs,
        action: event[:action],
        code: event[:check][:status],
        message: event[:check][:notification] || event[:check][:output],
        playbook: event[:check][:playbook] || '',
        duration: event[:check][:duration],
        api_endpoint: api_endpoint
      }

      job = {
        'class' => 'Notifu::Processor',
        'args' => [ payload ],
        'jid' => SecureRandom.hex(12),
        'retry' => true,
        'enqueued_at' => Time.now.to_f
      }

      begin
        @redis.lpush("queue:processor", JSON.dump(job))
      rescue Exception => e
        yield "failed to send event to Notifu #{e.message}", 1
      end

      yield "sent event to Notifu #{notifu_id}", 0
    end

    def stop
      yield
    end

  end
end
