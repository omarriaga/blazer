require "digest/md5"

module Blazer
  class DataSource
    attr_reader :id, :settings, :connection_model

    def initialize(id, settings)
      @id = id
      @settings = settings

      unless settings["url"] || Rails.env.development?
        raise Blazer::Error, "Empty url"
      end

      @connection_model =
        Class.new(Blazer::Connection) do
          def self.name
            "Blazer::Connection::#{object_id}"
          end
          establish_connection(settings["url"]) if settings["url"]
        end
    end

    def name
      settings["name"] || @id
    end

    def linked_columns
      settings["linked_columns"] || {}
    end

    def smart_columns
      settings["smart_columns"] || {}
    end

    def smart_variables
      settings["smart_variables"] || {}
    end

    def variable_defaults
      settings["variable_defaults"] || {}
    end

    def timeout
      settings["timeout"]
    end

    def cache
      @cache ||= begin
        if settings["cache"].is_a?(Hash)
          settings["cache"]
        elsif settings["cache"]
          {
            "mode" => "all",
            "expires_in" => settings["cache"]
          }
        else
          {
            "mode" => "off"
          }
        end
      end
    end

    def cache_mode
      cache["mode"]
    end

    def cache_expires_in
      (cache["expires_in"] || 60).to_f
    end

    def cache_slow_threshold
      (cache["slow_threshold"] || 15).to_f
    end

    def local_time_suffix
      @local_time_suffix ||= Array(settings["local_time_suffix"])
    end

    def use_transaction?
      settings.key?("use_transaction") ? settings["use_transaction"] : true
    end

    def cost(statement)
      if postgresql? || redshift?
        begin
          result = connection_model.connection.select_all("EXPLAIN #{statement}")
          match = /cost=\d+\.\d+..(\d+\.\d+) /.match(result.rows.first.first)
          match[1] if match
        rescue ActiveRecord::StatementInvalid
          # do nothing
        end
      end
    end

    def run_statement(statement, options = {})
      columns = nil
      rows = nil
      error = nil
      cached_at = nil
      just_cached = false
      cache_key = self.cache_key(statement) if cache
      if cache && !options[:refresh_cache]
        value = Blazer.cache.read(cache_key)
        columns, rows, cached_at = Marshal.load(value) if value
      end

      unless rows
        comment = "blazer"
        if options[:user].respond_to?(:id)
          comment << ",user_id:#{options[:user].id}"
        end
        if options[:user].respond_to?(Blazer.user_name)
          # only include letters, numbers, and spaces to prevent injection
          comment << ",user_name:#{options[:user].send(Blazer.user_name).to_s.gsub(/[^a-zA-Z0-9 ]/, "")}"
        end
        if options[:query].respond_to?(:id)
          comment << ",query_id:#{options[:query].id}"
        end
        columns, rows, error, just_cached = run_statement_helper(statement, comment)
      end

      output = [columns, rows, error, cached_at]
      output << just_cached if options[:with_just_cached]
      output
    end

    def clear_cache(statement)
      Blazer.cache.delete(cache_key(statement))
    end

    def cache_key(statement)
      ["blazer", "v3", id, Digest::MD5.hexdigest(statement)].join("/")
    end

    def schemas
      default_schema = (postgresql? || redshift?) ? "public" : connection_model.connection_config[:database]
      settings["schemas"] || [connection_model.connection_config[:schema] || default_schema]
    end

    def tables
      columns, rows, error, cached_at = run_statement(connection_model.send(:sanitize_sql_array, ["SELECT table_name, column_name, ordinal_position, data_type FROM information_schema.columns WHERE table_schema IN (?)", schemas]))
      rows.map(&:first).uniq
    end

    def postgresql?
      ["PostgreSQL", "PostGIS"].include?(adapter_name)
    end

    def redshift?
      ["Redshift"].include?(adapter_name)
    end

    def mysql?
      ["MySQL", "Mysql2", "Mysql2Spatial"].include?(adapter_name)
    end

    def reconnect
      connection_model.establish_connection(settings["url"])
    end

    protected

    def run_statement_helper(statement, comment)
      columns = []
      rows = []
      error = nil
      start_time = Time.now

      in_transaction do
        begin
          if timeout
            if postgresql? || redshift?
              connection_model.connection.execute("SET statement_timeout = #{timeout.to_i * 1000}")
            elsif mysql?
              connection_model.connection.execute("SET max_execution_time = #{timeout.to_i * 1000}")
            else
              raise Blazer::TimeoutNotSupported, "Timeout not supported for #{adapter_name} adapter"
            end
          end

          result = connection_model.connection.select_all("#{statement} /*#{comment}*/")
          columns = result.columns
          cast_method = Rails::VERSION::MAJOR < 5 ? :type_cast : :cast_value
          result.rows.each do |untyped_row|
            rows << (result.column_types.empty? ? untyped_row : columns.each_with_index.map { |c, i| untyped_row[i] ? result.column_types[c].send(cast_method, untyped_row[i]) : nil })
          end
        rescue ActiveRecord::StatementInvalid => e
          error = e.message.sub(/.+ERROR: /, "")
          error = Blazer::TIMEOUT_MESSAGE if Blazer::TIMEOUT_ERRORS.any? { |e| error.include?(e) }
        end
      end

      duration = Time.now - start_time
      just_cached = false
      if !error && (cache_mode == "all" || (cache_mode == "slow" && duration >= cache_slow_threshold))
        Blazer.cache.write(cache_key(statement), Marshal.dump([columns, rows, Time.now]), expires_in: cache_expires_in.to_f * 60)
        just_cached = true
      end

      [columns, rows, error, just_cached]
    end

    def adapter_name
      connection_model.connection.adapter_name
    end

    def in_transaction
      if use_transaction?
        connection_model.transaction do
          yield
          raise ActiveRecord::Rollback
        end
      else
        yield
      end
    end
  end
end
