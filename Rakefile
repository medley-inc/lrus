require 'rake/testtask'

task default: :test
Rake::TestTask.new

task :dbcreate do
  require "uri"
  require "pg"

  uri = URI.parse(ENV["DATABASE_URL"])
  connection = PG::Connection.new(
    host: uri.host,
    port: uri.port || 5432,
    dbname: "template1",
    user: uri.user,
    password: uri.password
  )
  dbname = uri.path[1..]
  result = connection.exec_params(<<~SQL, [dbname])
    SELECT datname FROM pg_database WHERE datname = $1 LIMIT 1
  SQL
  if result.ntuples.zero?
    result = connection.exec_params(<<~SQL)
      CREATE DATABASE #{dbname};
    SQL
    raise "Cannot create database" unless result.result_status == PG::PGRES_COMMAND_OK
  end

  connection = PG::Connection.new(ENV["DATABASE_URL"])
  result = connection.exec_params(File.read("schema.sql"))
  raise "Cannot import schema" unless result.result_status == PG::PGRES_COMMAND_OK
end
