ENV['RACK_ENV'] ||= 'development'
require 'bundler'
Bundler.require 'default', ENV['RACK_ENV']
MONGO = Mongo::Client.new(ENV.fetch('MONGOLAB_URI', 'mongodb://localhost:27017/lrus'), heartbeat_frequency: 60 * 60)

class App < Sinatra::Base
  get '/:name' do
    MONGO[:apps].find(name: params[:name]).limit(1).first.to_h.to_json
  end

  post '/:name/:branch' do
    name   = params[:name]
    branch = params[:branch]
    tmpl   = (params[:tmpl] || (name + '${n}')).gsub('$', '%')
    size   = (params[:size] || 3).to_i
    now    = Time.now

    app = MONGO[:apps].find(name: name).limit(1).first
    app ||= { name: name, servers: [] }

    servers = app[:servers]
    servers.push(n: servers.size + 1, t: now, b: '') while servers.size < size

    server = servers.find(-> { servers.min_by { |e| e[:t] } }) { |e| e[:b] == branch }
    server[:b] = branch
    server[:t] = now + 1

    if app[:_id]
      MONGO[:apps].update_one({ _id: app[:_id] }, app)
    else
      MONGO[:apps].insert_one(app)
    end

    tmpl % { name: name, n: server[:n], b: server[:b] }
  end
end
