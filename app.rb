require 'bundler/setup'
Bundler.require 'default'
require 'sinatra/base'
require 'pg'
require_relative 'apps'

class App < Sinatra::Base
  use Rack::Auth::Basic do |username, password|
    username == ENV['AUTH_USERNAME'] && password == ENV['AUTH_PASSWORD']
  end if ENV.key? 'AUTH_USERNAME' and ENV.key? 'AUTH_PASSWORD'

  enable :method_override

  set(:database_url) { ENV["DATABASE_URL"] }
  set(:database_connection_pool) do
    @pool ||= ConnectionPool.new { PG::Connection.new(settings.database_url) }
  end

  helpers do
    def error_404
      not_found '<h1>Not Found</h1>'
    end

    def error_406
      error 406, '<h1>Locked</h1>'
    end

    def error_500
      error 500, '<h1>Oops</h1>'
    end

    def lockable?(app)
      app[:servers].reject { |e| e[:l] }.size > 1
    end
  end

  error(Apps::Error) { error_500 }
  error(Apps::LockedError) { error_406 }
  error(Apps::NotFoundError) { error_404 }

  get '/' do
    list = settings.database_connection_pool.with do |connection|
      apps = Apps.new(connection: connection)
      apps.list
    end

    erb :names, locals: { apps: list }
  end

  post '/:name' do
    name = params[:name]
    tmpl = (params[:tmpl] || (name + '${n}')).gsub('$', '%')
    server = settings.database_connection_pool.with do |connection|
      apps = Apps.new(connection: connection)
      apps.alloc(
        name: name,
        branch: params[:branch],
        size: (params[:size] || 3).to_i,
        number: params[:number]
      )
    end

    tmpl % { name: name, n: server[:n], b: server[:b] }
  end

  post '/:name/:no/free' do
    settings.database_connection_pool.with do |connection|
      apps = Apps.new(connection: connection)
      apps.free(name: params[:name], number: params[:no])
    end

    redirect uri '/'
  end

  post '/:name/:no/lock' do
    settings.database_connection_pool.with do |connection|
      apps = Apps.new(connection: connection)
      apps.lock(name: params[:name], number: params[:no])
    end

    redirect uri '/'
  end

  delete '/:name/:no/lock' do
    settings.database_connection_pool.with do |connection|
      apps = Apps.new(connection: connection)
      apps.unlock(name: params[:name], number: params[:no])
    end

    redirect uri '/'
  end

  # github webhook
  post '/webhook/unlock/:name' do
    github_event = request.env['HTTP_X_GITHUB_EVENT']
    return "Not accepted event: #{github_event}" unless github_event == 'pull_request'

    body = request.body.read
    return "No body" if body == ''

    payload = JSON.parse(body)
    action = payload['action']
    return "Not accepted action: #{action}" unless action == 'closed'

    name = params[:name]
    branch = payload.dig('pull_request', 'head', 'ref')

    begin
      settings.database_connection_pool.with do |connection|
        apps = Apps.new(connection: connection)
        apps.unlock(name: name, branch: branch)
      end
      'ok'
    rescue Apps::AppNotFoundError
      "Not exist application: #{name}"
    rescue Apps::ServerNotFoundError
      "Not exist repository: #{branch}"
    end
  end
end
