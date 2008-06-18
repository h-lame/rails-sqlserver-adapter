require "cases/helper"
require 'models/default'
require 'models/post'
require 'models/task'

class SqlServerAdapterTest < ActiveRecord::TestCase
  class TableWithRealColumn < ActiveRecord::Base; end

  fixtures :posts, :tasks

  def setup
    @connection = ActiveRecord::Base.connection
  end

  def teardown
    @connection.execute("SET LANGUAGE us_english") rescue nil
  end

  def test_real_column_has_float_type
    assert_equal :float, TableWithRealColumn.columns_hash["real_number"].type
  end

  # SQL Server 2000 has a bug where some unambiguous date formats are not
  # correctly identified if the session language is set to german
  def test_date_insertion_when_language_is_german
    @connection.execute("SET LANGUAGE deutsch")

    assert_nothing_raised do
      Task.create(:starting => Time.utc(2000, 1, 31, 5, 42, 0), :ending => Date.new(2006, 12, 31))
    end
  end

  def test_indexes_with_descending_order
    # Make sure we have an index with descending order
    @connection.execute "CREATE INDEX idx_credit_limit ON accounts (credit_limit DESC)" rescue nil
    assert_equal ["credit_limit"], @connection.indexes('accounts').first.columns
  ensure
    @connection.execute "DROP INDEX accounts.idx_credit_limit"
  end

  def test_execute_without_block_closes_statement
    assert_all_statements_used_are_closed do
      @connection.execute("SELECT 1")
    end
  end

  def test_execute_with_block_closes_statement
    assert_all_statements_used_are_closed do
      @connection.execute("SELECT 1") do |sth|
        assert !sth.finished?, "Statement should still be alive within block"
      end
    end
  end

  def test_insert_with_identity_closes_statement
    assert_all_statements_used_are_closed do
      @connection.insert("INSERT INTO accounts ([id], [firm_id],[credit_limit]) values (999, 1, 50)")
    end
  end

  def test_insert_without_identity_closes_statement
    assert_all_statements_used_are_closed do
      @connection.insert("INSERT INTO accounts ([firm_id],[credit_limit]) values (1, 50)")
    end
  end

  def test_active_closes_statement
    assert_all_statements_used_are_closed do
      @connection.active?
    end
  end
  
  def assert_all_statements_used_are_closed(&block)
    existing_handles = []
    ObjectSpace.each_object(DBI::StatementHandle) {|handle| existing_handles << handle}
    GC.disable

    yield

    used_handles = []
    ObjectSpace.each_object(DBI::StatementHandle) {|handle| used_handles << handle unless existing_handles.include? handle}

    assert_block "No statements were used within given block" do
      used_handles.size > 0
    end

    ObjectSpace.each_object(DBI::StatementHandle) do |handle|
      assert_block "Statement should have been closed within given block" do
        handle.finished?
      end
    end
  ensure
    GC.enable
  end
end

class StringDefaultsTest < ActiveRecord::TestCase
  class StringDefaults < ActiveRecord::Base; end;

  def test_sqlserver_default_strings_before_save
    default = StringDefaults.new
    assert_equal nil, default.string_with_null_default
    assert_equal 'null', default.string_with_pretend_null_one
    assert_equal '(null)', default.string_with_pretend_null_two 
    assert_equal 'NULL', default.string_with_pretend_null_three
    assert_equal '(NULL)', default.string_with_pretend_null_four
  end
  
  def test_sqlserver_default_strings_after_save
    default = StringDefaults.create
    assert_equal nil, default.string_with_null_default
    assert_equal 'null', default.string_with_pretend_null_one
    assert_equal '(null)', default.string_with_pretend_null_two 
    assert_equal 'NULL', default.string_with_pretend_null_three
    assert_equal '(NULL)', default.string_with_pretend_null_four
  end
  
  
end

class SupportForSqlServerVersionInSqlServerAdapterTest < Test::Unit::TestCase
  def setup
    @config = ActiveRecord::Base.configurations['arunit'].dup
    @conn = nil
  end
  
  def teardown
    @conn.disconnect! unless @conn.nil?
  end

  def test_should_have_nil_sql_server_version_if_not_specified_in_connection_config
    @config.delete(:sql_server_version)
    @conn = ActiveRecord::Base.sqlserver_connection(@config)
    assert_nil @conn.instance_eval{@sql_server_version}
  end

  def test_should_have_same_sql_server_version_as_that_specified_in_connection_config
    @config[:sql_server_version] = 'Spanky'
    @conn = ActiveRecord::Base.sqlserver_connection(@config)
    assert_equal 'Spanky', @conn.instance_eval{@sql_server_version}
  end
end

class SupportForVarcharMaxInSqlServerAdapterTest < Test::Unit::TestCase
  def setup
    @config = ActiveRecord::Base.configurations['arunit'].dup
    @conn = nil
  end
  
  def teardown
    @conn.disconnect! unless @conn.nil?
  end
  
  def test_should_not_support_varchar_max_if_no_sql_server_version_set
    @config.delete(:sql_server_version)
    @conn = ActiveRecord::Base.sqlserver_connection(@config)
    assert !@conn.supports_varchar_max?
  end
  
  def test_should_not_support_varchar_max_if_sql_server_version_is_less_than_2005
    @config[:sql_server_version] = 2000
    @conn = ActiveRecord::Base.sqlserver_connection(@config)
    assert !@conn.supports_varchar_max?
  end

  def test_should_not_support_varchar_max_if_sql_server_version_is_a_string_that_is_less_than_2005
    @config[:sql_server_version] = '2000'
    @conn = ActiveRecord::Base.sqlserver_connection(@config)
    assert !@conn.supports_varchar_max?
  end
  
  def test_should_not_support_varchar_max_if_sql_server_version_is_not_a_string_that_turns_into_a_number
    @config[:sql_server_version] = 'dave'
    @conn = ActiveRecord::Base.sqlserver_connection(@config)
    assert !@conn.supports_varchar_max?
  end

  def test_should_support_varchar_max_if_sql_server_version_is_2005
    @config[:sql_server_version] = 2005
    @conn = ActiveRecord::Base.sqlserver_connection(@config)
    assert @conn.supports_varchar_max?
  end
  
  def test_should_not_support_varchar_max_if_sql_server_version_is_a_string_that_is_2005
    @config[:sql_server_version] = '2005'
    @conn = ActiveRecord::Base.sqlserver_connection(@config)
    assert @conn.supports_varchar_max?
  end

  def test_should_support_varchar_max_if_sql_server_version_is_greater_than_2005
    @config[:sql_server_version] = 2008
    @conn = ActiveRecord::Base.sqlserver_connection(@config)
    assert @conn.supports_varchar_max?
  end
  
  def test_should_not_support_varchar_max_if_sql_server_version_is_a_string_that_is_greater_than_2005
    @config[:sql_server_version] = '2008'
    @conn = ActiveRecord::Base.sqlserver_connection(@config)
    assert @conn.supports_varchar_max?
  end
end

class SupportForSimulatedTextDataTypeInSqlServerAdapterTest < Test::Unit::TestCase
  def setup
    @config = ActiveRecord::Base.configurations['arunit'].dup
    @conn = ActiveRecord::Base.sqlserver_connection(@config)
  end
  
  def teardown
    @conn.disconnect! unless @conn.nil?
  end
  
  def test_should_use_varchar_max_as_text_data_type_if_varchar_max_is_supported
    # Look ma! Super fake stubbing!
    def @conn.supports_varchar_max?
      true
    end
    tdt = @conn.simulated_text_data_type_for_sql_server
    assert_equal 'varchar', tdt[:name]
    assert_equal 'max', tdt[:limit]
  end

  def test_should_use_varchar_8000_as_text_data_type_if_varchar_max_is_not_supported
    # Look ma! Super fake stubbing!
    def @conn.supports_varchar_max?
      false
    end
    tdt = @conn.simulated_text_data_type_for_sql_server
    assert_equal 'varchar', tdt[:name]
    assert_equal 8000, tdt[:limit]
  end
end