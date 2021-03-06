require 'mysql'

class Mysql2psql

  class MysqlReader
    class Field
    end
  
    class Table
      attr_reader :name
    
      def initialize(reader, name)
        @reader = reader
        @name = name
      end
    
      @@types = %w(tiny enum decimal short long float double null timestamp longlong int24 date time datetime year set blob string var_string char).inject({}) do |list, type|
        list[eval("::Mysql::Field::TYPE_#{type.upcase}")] = type
        list
      end
    
      @@types[246] = "decimal"
    
      def columns
        @columns ||= load_columns
      end
    
      def convert_type(type)
        case type
        when /^int.* unsigned/
          "bigint"
        when /bigint/
          "bigint"
        when "bit(1)"
          "boolean"
        when /smallint.* unsigned/
          "integer"
        when /smallint/
          "smallint"
        when "tinyint(1)"
          "boolean"
        when /tinyint/
          "tinyint"
        when /int/
          "integer"
        when /varchar/
          "varchar"
        when /char/
          "char"          
        when /decimal/
          "decimal"
        when /float/
          "float"
        when /real|double/
          "double precision"
        else
          type
        end 
      end
    
      def load_columns
        @reader.reconnect
        result = @reader.mysql.list_fields(name)
        mysql_flags = ::Mysql::Field.constants.select {|c| c =~ /FLAG/}
        fields = []
        @reader.mysql.query("EXPLAIN `#{name}`") do |res|
          while field = res.fetch_row do
            length = -1
            length = field[1][/\((\d+)\)/, 1] if field[1] =~ /\((\d+)\)/
            length = field[1][/\((\d+),(\d+)\)/, 1] if field[1] =~ /\((\d+),(\d+)\)/
            desc = {
              :name => field[0],
              :table_name => name,
              :type => convert_type(field[1]),
              :length => length && length.to_i,
              :decimals => field[1][/\((\d+),(\d+)\)/, 2],
              :null => field[2] == "YES",
              :primary_key => field[3] == "PRI",
              :auto_increment => field[5] == "auto_increment"
              }
            desc[:default] = field[4] unless field[4].nil?
            fields << desc
          end
        end
 
        fields.select {|field| field[:auto_increment]}.each do |field|
          @reader.mysql.query("SELECT max(`#{field[:name]}`) FROM `#{name}`") do |res|
            field[:maxval] = res.fetch_row[0].to_i
          end
        end
        fields
      end
    
    
      def indexes
        load_indexes unless @indexes
        @indexes 
      end
 
      def foreign_keys
        load_indexes unless @foreign_keys
        @foreign_keys
      end
    
      def load_indexes
        @indexes = []
        @foreign_keys = []
      
        @reader.mysql.query("SHOW CREATE TABLE `#{name}`") do |result|
          explain = result.fetch_row[1]
          explain.split(/\n/).each do |line|
            next unless line =~ / KEY /
            index = {}
            if match_data = /CONSTRAINT `(\w+)` FOREIGN KEY \(`(\w+)`\) REFERENCES `(\w+)` \(`(\w+)`\)/.match(line)
              index[:name] = match_data[1]
              index[:column] = match_data[2]
              index[:ref_table] = match_data[3]
              index[:ref_column] = match_data[4]
              @foreign_keys << index
            elsif match_data = /KEY `(\w+)` \((.*)\)/.match(line)
              index[:name] = match_data[1]
              index[:columns] = match_data[2].split(",").map {|col| col[/`(\w+)`/, 1]}
              index[:unique] = true if line =~ /UNIQUE/
              @indexes << index
            elsif match_data = /PRIMARY KEY .*\((.*)\)/.match(line)
              index[:primary] = true
              index[:columns] = match_data[1].split(",").map {|col| col.strip.gsub(/`/, "")}
              @indexes << index
            end
          end
        end
      end
    
      def count_rows
        @reader.mysql.query("SELECT COUNT(*) FROM `#{name}`")  do |res|
          return res.fetch_row[0].to_i
        end
      end
    
      def has_id?
        !!columns.find {|col| col[:name] == "id"} 
      end
    
      def count_for_pager
        query = has_id? ? 'MAX(id)' : 'COUNT(*)'
        @reader.mysql.query("SELECT #{query} FROM `#{name}`") do |res|
          return res.fetch_row[0].to_i
        end
      end
 
      def query_for_pager
        query = has_id? ? 'WHERE id >= ? AND id < ?' : 'LIMIT ?,?'
        "SELECT #{columns.map{|c| "`"+c[:name]+"`"}.join(", ")} FROM `#{name}` #{query}"
      end
    end
  
    def connect
      @mysql = Mysql.connect(@host, @user, @passwd, @db, @port, @sock, @flag)
      @mysql.query("SET NAMES utf8")
      @mysql.query("SET SESSION query_cache_type = OFF")
    end
  
    def reconnect
      @mysql.close rescue false
      connect
    end
  
    def initialize(options)
      @host, @user, @passwd, @db, @port, @sock, @flag = 
        options.mysqlhostname('localhost'), options.mysqlusername, 
        options.mysqlpassword, options.mysqldatabase, 
        options.mysqlport, options.mysqlsocket(nil)
      connect
    end
  
    attr_reader :mysql
    
    def views
      unless defined? @views
        @mysql.query("SELECT t.TABLE_NAME FROM INFORMATION_SCHEMA.TABLES t WHERE t.TABLE_SCHEMA = '#{@db}' AND t.TABLE_TYPE = 'VIEW';") do |res|
          @views = []
          res.each { |row| @views << row[0] }
        end
      end
      
      @views
    end
    
    def tables
      @tables ||= (@mysql.list_tables - views).map do |table|
        Table.new(self, table)
      end
    end
  
    def paginated_read(table, page_size)
      count = table.count_for_pager
      return if count < 1
      statement = @mysql.prepare(table.query_for_pager)
      counter = 0
      0.upto((count + page_size)/page_size) do |i|
        statement.execute(i*page_size, table.has_id? ? (i+1)*page_size : page_size)
        while row = statement.fetch
          counter += 1
          yield(row, counter)
        end
      end
      counter
    end
  end

end
