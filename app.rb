ENV['RACK_ENV'] ||= 'development'
require 'bundler'
Bundler.require 'default', ENV['RACK_ENV']
require 'tilt/erb'
MONGO = Mongo::Client.new(ENV.fetch('MONGOLAB_URI', 'mongodb://127.0.0.1:27017/lrus'), heartbeat_frequency: 60 * 60)

class App < Sinatra::Base
  use Rack::Auth::Basic do |username, password|
    username == ENV['AUTH_USERNAME'] && password == ENV['AUTH_PASSWORD']
  end if ENV.key? 'AUTH_USERNAME' and ENV.key? 'AUTH_PASSWORD'

  enable :method_override

  helpers do
    def error_404
      not_found '<h1>Not Found</h1>'
    end

    def app_and_server(name, no)
      app = MONGO[:apps].find(name: name).limit(1).first
      error_404 unless app

      server = app[:servers].find { |e| e[:n] == no.to_i }
      error_404 unless server

      [app, server]
    end

    def lockable?(app)
      app[:servers].reject { |e| e[:l] }.size > 1
    end
  end

  get '/' do
    apps = MONGO[:apps].find

    erb :names, locals: { apps: apps }
  end

  post '/:name' do
    name   = params[:name]
    branch = params[:branch]
    tmpl   = (params[:tmpl] || (name + '${n}')).gsub('$', '%')
    size   = (params[:size] || 3).to_i
    size   = 1 if size < 1
    number = params[:number]
    now    = Time.now

    app = MONGO[:apps].find(name: name).limit(1).first
    app ||= { name: name, servers: [] }

    servers = app[:servers]
    servers.push(n: servers.size + 1, t: now, b: '') while servers.size < size
    servers.pop while servers.size > size

    server = if number
               n = Integer(number)
               servers.find { |e| e[:n] == n }
             else
               servers.find { |e| e[:b] == branch }
             end

    unless server
      available_servers = servers.reject { |e| e[:l] }
      error 406, '<h1>Locked</h1>' if available_servers.empty?
      server = available_servers.find { |e| e[:b].empty? } || available_servers.min_by { |e| e[:t] }
    end

    server[:b] = branch
    server[:t] = now + 1

    if app[:_id]
      MONGO[:apps].update_one({ _id: app[:_id] }, app)
    else
      MONGO[:apps].insert_one(app)
    end

    tmpl % { name: name, n: server[:n], b: server[:b] }
  end

  post '/:name/:no/free' do
    app, server = app_and_server params[:name], params[:no]

    server[:b] = ''
    server[:t] = Time.now
    server.delete :l

    MONGO[:apps].update_one({ _id: app[:_id] }, app)

    redirect uri "/"
  end

  post '/:name/:no/lock' do
    app, server = app_and_server params[:name], params[:no]

    server[:l] = true

    MONGO[:apps].update_one({ _id: app[:_id] }, app)

    redirect uri "/"
  end

  delete '/:name/:no/lock' do
    app, server = app_and_server params[:name], params[:no]

    server.delete :l

    MONGO[:apps].update_one({ _id: app[:_id] }, app)

    redirect uri "/"
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
    app = MONGO[:apps].find(name: name).limit(1).first
    return "Not exist application: #{name}" unless app

    repo_name = payload.dig('pull_request', 'head', 'ref')
    server = app[:servers].find { |e| e[:b] == repo_name }
    return "Not exist repository: #{repo_name}" unless server

    server.delete :l

    MONGO[:apps].update_one({ _id: app[:_id] }, app)

    'ok'
  end
end
