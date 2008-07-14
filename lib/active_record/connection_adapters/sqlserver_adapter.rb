require 'active_record/connection_adapters/abstract_adapter'

require 'base64'
require 'bigdecimal'
require 'bigdecimal/util'

# sqlserver_adapter.rb -- ActiveRecord adapter for Microsoft SQL Server
#
# Author: Joey Gibson <joey@joeygibson.com>
# Date:   10/14/2004
#
# Modifications: DeLynn Berry <delynnb@megastarfinancial.com>
# Date: 3/22/2005
#
# Modifications (ODBC): Mark Imbriaco <mark.imbriaco@pobox.com>
# Date: 6/26/2005

# Modifications (Migrations): Tom Ward <tom@popdog.net>
# Date: 27/10/2005
#
# Modifications (Numerous fixes as maintainer): Ryan Tomayko <rtomayko@gmail.com>
# Date: Up to July 2006

# Current maintainer: Tom Ward <tom@popdog.net>

module ActiveRecord
  class Base
    def self.sqlserver_connection(config) #:nodoc:
      require_library_or_gem 'dbi' unless self.class.const_defined?(:DBI)
      
      config = config.symbolize_keys

      mode        = config[:mode] ? config[:mode].to_s.upcase : 'ADO'
      username    = config[:username] ? config[:username].to_s : 'sa'
      password    = config[:password] ? config[:password].to_s : ''
      autocommit  = config.key?(:autocommit) ? config[:autocommit] : true
      if mode == "ODBC"
        raise ArgumentError, "Missing DSN. Argument ':dsn' must be set in order for this adapter to work." unless config.has_key?(:dsn)
        dsn       = config[:dsn]
        driver_url = "DBI:ODBC:#{dsn}"
      else
        raise ArgumentError, "Missing Database. Argument ':database' must be set in order for this adapter to work." unless config.has_key?(:database)
        database  = config[:database]
        host      = config[:host] ? config[:host].to_s : 'localhost'
        driver_url = "DBI:ADO:Provider=SQLOLEDB;Data Source=#{host};Initial Catalog=#{database};User ID=#{username};Password=#{password};"
      end
      conn      = DBI.connect(driver_url, username, password)
      conn["AutoCommit"] = autocommit
      ConnectionAdapters::SQLServerAdapter.new(conn, logger, [driver_url, username, password])
    end
  end # class Base

  module ConnectionAdapters
    class SQLServerColumn < Column# :nodoc:
      attr_reader :identity, :is_special

      def initialize(info)
        if info[:type] =~ /numeric|decimal/i
          type = "#{info[:type]}(#{info[:numeric_precision]},#{info[:numeric_scale]})"
        else
          type = "#{info[:type]}(#{info[:length]})"
        end
        super(info[:name], info[:default_value], type, info[:is_nullable])
        @identity = info[:is_identity]
        @is_special = ["text", "ntext", "image"].include?(info[:type])
        # TODO: check ok to remove @scale = scale_value
        # SQL Server only supports limits on *char and float types
        @limit = nil unless @type == :float or @type == :string
      end

      def simplified_type(field_type)
        case field_type
          when /real/i              then :float
          when /money/i             then :decimal
          when /image/i             then :binary
          when /bit/i               then :boolean
          when /uniqueidentifier/i  then :string
          when /text/i              then :real_text
          when /varchar(max|8000)/i then :text
          else super
        end
      end

      def type_cast(value)
        return nil if value.nil?
        case type
        when :real_text then value
        when :datetime  then cast_to_datetime(value)
        when :timestamp then cast_to_time(value)
        when :time      then cast_to_time(value)
        when :date      then cast_to_datetime(value)
        else super
        end
      end
      
      def type_cast_code(var_name)
        case type
        when :datetime  then "#{self.class.name}.cast_to_datetime(#{var_name})"
        when :timestamp then "#{self.class.name}.cast_to_time(#{var_name})"
        when :time      then "#{self.class.name}.cast_to_time(#{var_name})"
        when :date      then "#{self.class.name}.cast_to_datetime(#{var_name})"
        else super
        end
      end
      
      class << self
        def cast_to_time(value)
          return value if value.is_a?(Time)
          time_array = ParseDate.parsedate(value)
          Time.time_with_datetime_fallback(Base.default_timezone, *time_array) rescue nil
          #Time.send(Base.default_timezone, *time_array) rescue nil
        end

        def cast_to_datetime(value)
          return value.to_time if value.is_a?(DBI::Timestamp)
          if value.is_a?(Time)
            if value.year != 0 and value.month != 0 and value.day != 0
              return value
            else
              return Time.mktime(2000, 1, 1, value.hour, value.min, value.sec) rescue nil
            end
          end
   
          if value.is_a?(DateTime)
            return Time.time_with_datetime_fallback(Base.default_timezone, value.year, value.mon, value.day, value.hour, value.min, value.sec)
          end
        
          return cast_to_time(value) if value.is_a?(Date) or value.is_a?(String) rescue nil
          value
        end
        
        # TODO: Find less hack way to convert DateTime objects into Times
        def string_to_time(value)
          if value.is_a?(DateTime)
            return Time.time_with_datetime_fallback(Base.default_timezone, value.year, value.mon, value.day, value.hour, value.min, value.sec)
          else
            super
          end
        end

        # These methods will only allow the adapter to insert binary data with a length of 7K or less
        # because of a SQL Server statement length policy.
        def string_to_binary(value) 
   	      Base64.encode64(value) 
        end 
 	       
   	    def binary_to_string(value) 
   	      Base64.decode64(value) 
   	    end
   	  end
    end

    # In ADO mode, this adapter will ONLY work on Windows systems, 
    # since it relies on Win32OLE, which, to my knowledge, is only 
    # available on Windows.
    #
    # This mode also relies on the ADO support in the DBI module. If you are using the
    # one-click installer of Ruby, then you already have DBI installed, but
    # the ADO module is *NOT* installed. You will need to get the latest
    # source distribution of Ruby-DBI from http://ruby-dbi.sourceforge.net/
    # unzip it, and copy the file 
    # <tt>src/lib/dbd_ado/ADO.rb</tt> 
    # to
    # <tt>X:/Ruby/lib/ruby/site_ruby/1.8/DBD/ADO/ADO.rb</tt> 
    # (you will more than likely need to create the ADO directory).
    # Once you've installed that file, you are ready to go.
    #
    # In ODBC mode, the adapter requires the ODBC support in the DBI module which requires
    # the Ruby ODBC module.  Ruby ODBC 0.996 was used in development and testing,
    # and it is available at http://www.ch-werner.de/rubyodbc/
    #
    # Options:
    #
    # * <tt>:mode</tt>      -- ADO or ODBC. Defaults to ADO.
    # * <tt>:username</tt>  -- Defaults to sa.
    # * <tt>:password</tt>  -- Defaults to empty string.
    # * <tt>:windows_auth</tt> -- Defaults to "User ID=#{username};Password=#{password}"
    #
    # ADO specific options:
    #
    # * <tt>:host</tt>      -- Defaults to localhost.
    # * <tt>:database</tt>  -- The name of the database. No default, must be provided.
    # * <tt>:windows_auth</tt> -- Use windows authentication instead of username/password.
    #
    # ODBC specific options:                   
    #
    # * <tt>:dsn</tt>       -- Defaults to nothing.
    #
    # Useful for text handling options:
    # * <tt>:sql_server_version</tt> -- The version of sql server you are connecting to 
    #                                   (7.0, 2000, 2005, 2008 etc...). >= 2005 will use
    #                                   varchar(max) instead of text, < 2005 will use
    #                                   varchar(8000) instead of text.
    #
    # ADO code tested on Windows 2000 and higher systems,
    # running ruby 1.8.2 (2004-07-29) [i386-mswin32], and SQL Server 2000 SP3.
    #
    # ODBC code tested on a Fedora Core 4 system, running FreeTDS 0.63, 
    # unixODBC 2.2.11, Ruby ODBC 0.996, Ruby DBI 0.0.23 and Ruby 1.8.2.
    # [Linux strongmad 2.6.11-1.1369_FC4 #1 Thu Jun 2 22:55:56 EDT 2005 i686 i686 i386 GNU/Linux]
    class SQLServerAdapter < AbstractAdapter
    
      def initialize(connection, logger, connection_options=nil)
        super(connection, logger)
        @sql_server_version = (connection_options || {}).delete(:sql_server_version)
        @connection_options = connection_options
      end

      def native_database_types
        {
          :primary_key => "int NOT NULL IDENTITY(1, 1) PRIMARY KEY",
          :string      => { :name => "varchar", :limit => 255  },
          :text        => simulated_text_data_type_for_sql_server,
          :integer     => { :name => "int" },
          :float       => { :name => "float", :limit => 8 },
          :decimal     => { :name => "decimal" },
          :datetime    => { :name => "datetime" },
          :timestamp   => { :name => "datetime" },
          :time        => { :name => "datetime" },
          :date        => { :name => "datetime" },
          :binary      => { :name => "image" },
          :boolean     => { :name => "bit" },
          :real_text   => { :name => 'text' },
        }
      end

      def adapter_name
        'SQLServer'
      end
      
      def simulated_text_data_type_for_sql_server
        if supports_varchar_max?
          {:name => 'varchar', :limit => 'max' }
        else
          {:name => 'varchar', :limit => 8000 }
        end
      end
      
      def supports_migrations? #:nodoc:
        true
      end

      def supports_varchar_max?
        (@sql_server_version && @sql_server_version.to_i >= 2005)
      end

      def type_to_sql(type, limit = nil, precision = nil, scale = nil) #:nodoc:
        return super unless type.to_s == 'integer'
        
        if limit.nil? || limit == 4
          'integer'
        elsif limit < 4
          'smallint'
        else
          'bigint'
        end
      end

      # CONNECTION MANAGEMENT ====================================#

      # Returns true if the connection is active.
      def active?
        @connection.execute("SELECT 1").finish
        true
      rescue DBI::DatabaseError, DBI::InterfaceError
        false
      end

      # Reconnects to the database, returns false if no connection could be made.
      def reconnect!
        disconnect!
        @connection = DBI.connect(*@connection_options)
      rescue DBI::DatabaseError => e
        @logger.warn "#{adapter_name} reconnection failed: #{e.message}" if @logger
        false
      end
      
      # Disconnects from the database
      
      def disconnect!
        @connection.disconnect rescue nil
      end

      def select_rows(sql, name = nil)
        rows = []
        repair_special_columns(sql)
        log(sql, name) do
          @connection.select_all(sql) do |row|
            record = []
            row.each do |col|
              if col.is_a? DBI::Timestamp
                record << col.to_time
              else
                record << col
              end
            end
            rows << record
          end
        end
        rows
      end

      def columns(table_name, name = nil)
        return [] if table_name.blank?
        table_name = table_name.to_s.split('.')[-1]
        table_name = table_name.gsub(/[\[\]]/, '')
        sql = %{
          SELECT 
          columns.COLUMN_NAME as name,
          columns.DATA_TYPE as type,  
          CASE
            WHEN columns.COLUMN_DEFAULT = '(null)' OR columns.COLUMN_DEFAULT = '(NULL)' THEN NULL
            ELSE columns.COLUMN_DEFAULT
          END default_value,
          columns.NUMERIC_SCALE as numeric_scale,
          columns.NUMERIC_PRECISION as numeric_precision,  
          COL_LENGTH(columns.TABLE_NAME, columns.COLUMN_NAME) as length,  
          CASE
            WHEN constraint_column_usage.constraint_name IS NULL THEN NULL
            ELSE 1
          END is_primary_key,
          CASE
            WHEN columns.IS_NULLABLE = 'YES' THEN 1
            ELSE NULL
          end is_nullable,
          CASE
            WHEN COLUMNPROPERTY(OBJECT_ID(columns.TABLE_NAME), columns.COLUMN_NAME, 'IsIdentity') = 0 THEN NULL
            ELSE 1
          END is_identity
          FROM INFORMATION_SCHEMA.COLUMNS columns
          LEFT OUTER JOIN INFORMATION_SCHEMA.TABLE_CONSTRAINTS primary_key_constraints ON (
            primary_key_constraints.table_name = columns.table_name 
            AND primary_key_constraints.constraint_type = 'PRIMARY KEY'
          )
          LEFT OUTER JOIN INFORMATION_SCHEMA.CONSTRAINT_COLUMN_USAGE constraint_column_usage ON (
            constraint_column_usage.table_name = primary_key_constraints.table_name 
            AND constraint_column_usage.column_name = columns.column_name
          )
          WHERE columns.TABLE_NAME = '#{table_name}'
          ORDER BY columns.ordinal_position
        }

        result = select(sql, name, true)
        result.collect do |column_info|
          # Remove brackets and outer quotes (if quoted) of default value returned by db, i.e:
          #   "(1)" => "1", "('1')" => "1", "((-1))" => "-1", "('(-1)')" => "(-1)"
          column_info.symbolize_keys!
          column_info[:default_value] = column_info[:default_value].match(/\A\(+'?(.*?)'?\)+\Z/)[1] if column_info[:default_value]
          SQLServerColumn.new(column_info)
        end
      end
      
      def empty_insert_statement(table_name)
        "INSERT INTO #{table_name} DEFAULT VALUES"
      end      

      def insert_sql(sql, name = nil, pk = nil, id_value = nil, sequence_name = nil)
        super || select_value("SELECT @@IDENTITY AS Ident")
      end

      def update_sql(sql, name = nil)          
        autoCommiting = @connection["AutoCommit"]
        begin
          begin_db_transaction if autoCommiting
          execute(sql, name)
          affectedRows = select_value("SELECT @@ROWCOUNT AS AffectedRows")
          commit_db_transaction if autoCommiting
          affectedRows
        rescue
          rollback_db_transaction if autoCommiting
          raise
        end                    
      end

      def execute(sql, name = nil)
        if sql =~ /^\s*INSERT/i && (table_name = query_requires_identity_insert?(sql))
          log(sql, name) do
            with_identity_insert_enabled(table_name) do 
              @connection.execute(sql) do |handle|
                yield(handle) if block_given?
              end
            end
          end
        else
          log(sql, name) do
            @connection.execute(sql) do |handle|
              yield(handle) if block_given?
            end
          end
        end
      end

      def begin_db_transaction
        @connection["AutoCommit"] = false
      rescue Exception => e
        @connection["AutoCommit"] = true
      end

      def commit_db_transaction
        @connection.commit
      ensure
        @connection["AutoCommit"] = true
      end

      def rollback_db_transaction
        @connection.rollback
      ensure
        @connection["AutoCommit"] = true
      end

      def quote(value, column = nil)
        return value.quoted_id if value.respond_to?(:quoted_id)

        case value
          when TrueClass             then '1'
          when FalseClass            then '0'
          else
            if value.acts_like?(:time)
              "'#{value.strftime("%Y%m%d %H:%M:%S")}'"
            elsif value.acts_like?(:date)
              "'#{value.strftime("%Y%m%d")}'"
            else
              super
            end
        end
      end

      def quote_string(string)
        string.gsub(/\'/, "''")
      end

      def quote_column_name(name)
        "[#{name}]"
      end

      def add_limit_offset!(sql, options)
        if options[:limit] and options[:offset]
          total_rows = @connection.select_all("SELECT count(*) as TotalRows from (#{sql.gsub(/\bSELECT(\s+DISTINCT)?\b/i, "SELECT#{$1} TOP 1000000000")}) tally")[0][:TotalRows].to_i
          if (options[:limit] + options[:offset]) >= total_rows
            options[:limit] = (total_rows - options[:offset] >= 0) ? (total_rows - options[:offset]) : 0
          end
          sql.sub!(/^\s*SELECT(\s+DISTINCT)?/i, "SELECT * FROM (SELECT TOP #{options[:limit]} * FROM (SELECT#{$1} TOP #{options[:limit] + options[:offset]} ")
          sql << ") AS tmp1"
          if options[:order]
            order = options[:order].split(',').map do |field|
              parts = field.split(" ")
              tc = parts[0]
              if sql =~ /\.\[/ and tc =~ /\./ # if column quoting used in query
                tc.gsub!(/\./, '\\.\\[')
                tc << '\\]'
              end
              if sql =~ /#{tc} AS (t\d_r\d\d?)/
                parts[0] = $1
              elsif parts[0] =~ /\w+\.(\w+)/
                parts[0] = $1
              end
              parts.join(' ')
            end.join(', ')
            sql << " ORDER BY #{change_order_direction(order)}) AS tmp2 ORDER BY #{order}"
          else
            sql << " ) AS tmp2"
          end
        elsif sql !~ /^\s*SELECT (@@|COUNT\()/i
          sql.sub!(/^\s*SELECT(\s+DISTINCT)?/i) do
            "SELECT#{$1} TOP #{options[:limit]}"
          end unless options[:limit].nil?
        end
      end

      def add_lock!(sql, options)
        @logger.info "Warning: SQLServer :lock option '#{options[:lock].inspect}' not supported" if @logger && options.has_key?(:lock)
        sql
      end

      def recreate_database(name)
        drop_database(name)
        create_database(name)
      end

      def drop_database(name)
        execute "DROP DATABASE #{name}"
      end

      def create_database(name)
        execute "CREATE DATABASE #{name}"
      end
   
      def current_database
        @connection.select_one("select DB_NAME()")[0]
      end

      def tables(name = nil)
        execute("SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE'", name) do |sth|
          result = sth.inject([]) do |tables, field|
            table_name = field[0]
            tables << table_name unless table_name == 'dtproperties'            
            tables
          end
        end
      end

      def indexes(table_name, name = nil)
        ActiveRecord::Base.connection.instance_variable_get("@connection")["AutoCommit"] = false
        __indexes(table_name, name)
      ensure
        ActiveRecord::Base.connection.instance_variable_get("@connection")["AutoCommit"] = true
      end
            
      def rename_table(name, new_name)
        execute "EXEC sp_rename '#{name}', '#{new_name}'"
      end

      def add_column(table_name, column_name, type, options = {})
        add_column_sql = "ALTER TABLE #{table_name} ADD #{quote_column_name(column_name)} #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}"      
        add_column_options!(add_column_sql, options)
        # TODO: Add support to mimic date columns, using constraints to mark them as such in the database
        # add_column_sql << " CONSTRAINT ck__#{table_name}__#{column_name}__date_only CHECK ( CONVERT(CHAR(12), #{quote_column_name(column_name)}, 14)='00:00:00:000' )" if type == :date       
        execute(add_column_sql)
      end
       
      def rename_column(table, column, new_column_name)
        execute "EXEC sp_rename '#{table}.#{column}', '#{new_column_name}'"
      end
      
      def change_column(table_name, column_name, type, options = {}) #:nodoc:
        sql = "ALTER TABLE #{table_name} ALTER COLUMN #{quote_column_name(column_name)} #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}"
        sql << " NOT NULL" if options[:null] == false
        sql_commands = [sql]        
        if options_include_default?(options)
          remove_default_constraint(table_name, column_name)
          sql_commands << "ALTER TABLE #{table_name} ADD CONSTRAINT DF_#{table_name}_#{column_name} DEFAULT #{quote(options[:default], options[:column])} FOR #{quote_column_name(column_name)}"
        end
        sql_commands.each {|c|
          execute(c)
        }
      end
      
      def change_column_default(table_name, column_name, default)
        remove_default_constraint(table_name, column_name)
        execute "ALTER TABLE #{table_name} ADD CONSTRAINT DF_#{table_name}_#{column_name} DEFAULT #{quote(default, column_name)} FOR #{quote_column_name(column_name)}"  
      end
      
      def remove_column(table_name, column_name)
        remove_check_constraints(table_name, column_name)
        remove_default_constraint(table_name, column_name)
        remove_indexes(table_name, column_name)
        execute "ALTER TABLE [#{table_name}] DROP COLUMN #{quote_column_name(column_name)}"
      end
      
      def remove_default_constraint(table_name, column_name)
        constraints = select "select def.name from sysobjects def, syscolumns col, sysobjects tab where col.cdefault = def.id and col.name = '#{column_name}' and tab.name = '#{table_name}' and col.id = tab.id"
        
        constraints.each do |constraint|
          execute "ALTER TABLE #{table_name} DROP CONSTRAINT #{constraint["name"]}"
        end
      end
      
      def remove_check_constraints(table_name, column_name)
        # TODO remove all constraints in single method
        constraints = select "SELECT CONSTRAINT_NAME FROM INFORMATION_SCHEMA.CONSTRAINT_COLUMN_USAGE where TABLE_NAME = '#{table_name}' and COLUMN_NAME = '#{column_name}'"
        constraints.each do |constraint|
          execute "ALTER TABLE #{table_name} DROP CONSTRAINT #{constraint["CONSTRAINT_NAME"]}"
        end
      end
      
      def remove_indexes(table_name, column_name)
        __indexes(table_name).select {|idx| idx.columns.include? column_name }.each do |idx|
          remove_index(table_name, {:name => idx.name})
        end
      end
      
      def remove_index(table_name, options = {})
        execute "DROP INDEX #{table_name}.#{quote_column_name(index_name(table_name, options))}"
      end

      private
        def __indexes(table_name, name = nil)
          indexes = []        
          execute("EXEC sp_helpindex '#{table_name}'", name) do |handle|
            if handle.column_info.any?
              handle.each do |index| 
                unique = index[1] =~ /unique/
                primary = index[1] =~ /primary key/
                if !primary
                  indexes << IndexDefinition.new(table_name, index[0], unique, index[2].split(", ").map {|e| e.gsub('(-)','')})
                end
              end
            end
          end
          indexes
        end
      
      
        def select(sql, name = nil, ignore_special_columns = false)
          repair_special_columns(sql) unless ignore_special_columns

          result = []          
          execute(sql) do |handle|
            handle.each do |row|
              row_hash = {}
              row.each_with_index do |value, i|
                if value.is_a? DBI::Timestamp
                  value = DateTime.new(value.year, value.month, value.day, value.hour, value.minute, value.sec)
                end
                row_hash[handle.column_names[i]] = value
              end
              result << row_hash
            end
          end
          result
        end

        # Turns IDENTITY_INSERT ON for table during execution of the block
        # N.B. This sets the state of IDENTITY_INSERT to OFF after the
        # block has been executed without regard to its previous state

        def with_identity_insert_enabled(table_name, &block)
          set_identity_insert(table_name, true)
          yield
        ensure
          set_identity_insert(table_name, false)  
        end
        
        def set_identity_insert(table_name, enable = true)
          execute "SET IDENTITY_INSERT #{table_name} #{enable ? 'ON' : 'OFF'}"
        rescue Exception => e
          raise ActiveRecordError, "IDENTITY_INSERT could not be turned #{enable ? 'ON' : 'OFF'} for table #{table_name}"  
        end

        def get_table_name(sql)
          if sql =~ /^\s*insert\s+into\s+([^\(\s]+)\s*|^\s*update\s+([^\(\s]+)\s*/i
            $1
          elsif sql =~ /from\s+([^\(\s]+)\s*/i
            $1
          else
            nil
          end
        end

        def identity_column(table_name)
          @table_columns = {} unless @table_columns
          @table_columns[table_name] = columns(table_name) if @table_columns[table_name] == nil
          @table_columns[table_name].each do |col|
            return col.name if col.identity
          end

          return nil
        end

        def query_requires_identity_insert?(sql)
          table_name = get_table_name(sql)
          id_column = identity_column(table_name)
          sql =~ /\[#{id_column}\]/ ? table_name : nil
        end

        def change_order_direction(order)
          order.split(",").collect {|fragment|
            case fragment
              when  /\bDESC\b/i     then fragment.gsub(/\bDESC\b/i, "ASC")
              when  /\bASC\b/i      then fragment.gsub(/\bASC\b/i, "DESC")
              else                  String.new(fragment).split(',').join(' DESC,') + ' DESC'
            end
          }.join(",")
        end

        def get_special_columns(table_name)
          special = []
          @table_columns ||= {}
          @table_columns[table_name] ||= columns(table_name)
          @table_columns[table_name].each do |col|
            special << col.name if col.is_special
          end
          special
        end

        def repair_special_columns(sql)
          special_cols = get_special_columns(get_table_name(sql))
          for col in special_cols.to_a
            sql.gsub!(/((\.|\s|\()\[?#{col.to_s}\]?)\s?=\s?/, '\1 LIKE ')
            sql.gsub!(/ORDER BY #{col.to_s}/i, '')
          end
          sql
        end

    end #class SQLServerAdapter < AbstractAdapter
    
    class TableDefinitions
      def real_text(*args)
        options = args.extract_options!
        column_names = args

        column_names.each { |name| column(name, 'real_text', options) }
      end
    end
    
  end #module ConnectionAdapters
end #module ActiveRecord
