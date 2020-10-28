# frozen_string_literal: true

class Apps
  Server = Struct.new(:n, :t, :b, :l) do
    def as_json(*)
      { n: n, t: t.iso8601(3), b: b, l: l }
    end
  end

  Error = Class.new StandardError
  LockedError = Class.new Error
  CreateError = Class.new Error
  UpdateError = Class.new Error
  NotFoundError = Class.new Error
  AppNotFoundError = Class.new NotFoundError
  ServerNotFoundError = Class.new NotFoundError

  attr_reader :connection

  # @param connection [PG::Connection]
  def initialize(connection:)
    @connection = connection
  end

  # @return [Array<Hash>]
  #   * :name (String)
  #   * :servers (Array<Server>)
  def list
    result = connection.exec_params(<<~SQL)
      SELECT name, servers FROM apps
    SQL
    return [] if result.ntuples.zero?

    result.each.map do |row|
      {
        name: row['name'],
        servers: parse_servers(row['servers'])
      }
    end
  end

  # @param name [String]
  # @param branch [String]
  # @param size [String]
  # @param number [String]
  # @param now [Time]
  # @return [Server]
  # @raise [LockedError]
  # @raise [CreateError]
  # @raise [UpdateError]
  def alloc(name:, branch:, size:, number:, now: Time.now)
    connection.transaction do |connection|
      result = connection.exec_params(<<~SQL, [name])
        SELECT servers FROM apps WHERE name = $1 LIMIT 1 FOR UPDATE
      SQL
      is_new_record = result.ntuples.zero?

      if result.ntuples.zero?
        servers = []
      else
        servers = parse_servers result[0]['servers']
      end
      servers.push(Server.new(servers.size + 1, now, '', false)) while servers.size < size
      servers.pop while servers.size > size

      server = find_server servers, branch: branch, number: number

      unless server
        available_servers = servers.reject { _1[:l] }
        raise LockedError if available_servers.empty?

        server = available_servers.find { _1[:b].empty? } || available_servers.min_by { _1[:t] }
      end

      server[:b] = branch
      server[:t] = now + 1

      if is_new_record
        result = connection.exec_params(<<~SQL, [name, dump_servers(servers)])
          INSERT INTO apps (name, servers) VALUES ($1, $2::JSONB)
        SQL
        unless result.result_status == PG::PGRES_COMMAND_OK
          raise CreateError.new("Cannot create apps (name=#{name}}")
        end
      else
        result = connection.exec_params(<<~SQL, [name, dump_servers(servers)])
          UPDATE apps SET servers = $2::JSONB WHERE name = $1
        SQL
        unless result.result_status == PG::PGRES_COMMAND_OK
          raise UpdateError.new("Cannot update apps (name=#{name})")
        end
      end

      server
    end
  end

  # @param name [String]
  # @param number [String]
  # @return [void]
  def free(name:, number:)
    find_and_lock(name: name, number: number) do |server|
      server[:b].clear
      server[:t] = Time.now
      server[:l] = false
    end
  end

  # @param name [String]
  # @param number [String]
  # @return [void]
  def lock(name:, number:)
    find_and_lock(name: name, number: number) do |server|
      server[:l] = true
    end
  end

  # @param name [String]
  # @param number [String, nil]
  # @param branch [String, nil]
  # @return [void]
  def unlock(name:, number: nil, branch: nil)
    find_and_lock(name: name, number: number, branch: branch) do |server|
      server[:l] = false
    end
  end

  private

  # @param name [String]
  # @param number [String]
  # @param branch [String, nil]
  # @return [void]
  # @yieldparam server [Server]
  # @raise [NotFoundError]
  # @raise [UpdateError]
  def find_and_lock(name:, number:, branch: nil)
    connection.transaction do |connection|
      result = connection.exec_params(<<~SQL, [name])
        SELECT servers FROM apps WHERE name = $1 LIMIT 1 FOR UPDATE
      SQL
      if result.result_status != PG::PGRES_TUPLES_OK || result.ntuples.zero?
        raise AppNotFoundError.new("Cannot find apps (name=#{name})")
      end

      servers = parse_servers result[0]['servers']
      server = find_server servers, number: number, branch: branch
      raise ServerNotFoundError.new("Cannot find server (number=#{number}, branch=#{branch})") unless server

      yield server

      result = connection.exec_params(<<~SQL, [name, dump_servers(servers)])
        UPDATE apps SET servers = $2::JSONB WHERE name = $1
      SQL
      unless result.result_status == PG::PGRES_COMMAND_OK
        raise UpdateError.new("Cannot update apps (name=#{name})")
      end
    end
  end

  # @param servers [String]
  # @return [Array<Server>]
  def parse_servers(servers)
    JSON.parse(servers, symbolize_names: true).map do
      Server.new(_1[:n], Time.parse(_1[:t]), _1[:b], _1[:l])
    end
  end

  # @param servers [Array<Server>]
  # @return [String]
  def dump_servers(servers)
    servers.map(&:as_json).to_json
  end

  # @param servers [Array<Server>]
  # @param branch [String, nil]
  # @param number [String, nil]
  # @return [Server, nil]
  def find_server(servers, branch: nil, number: nil)
    if number
      n = Integer(number)
      servers.find { _1[:n] == n }
    elsif branch
      servers.find { _1[:b] == branch }
    end
  end
end
