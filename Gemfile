source 'https://rubygems.org'
ruby File.read(File.join(File.dirname(__FILE__), '.ruby-version')).strip

gem 'pg'
gem 'puma'
gem 'rack'
gem 'sinatra', require: 'sinatra/base'
gem 'json'
gem 'connection_pool'

group :test do
  gem 'rake'
  gem 'rack-test', require: 'rack/test'
  gem 'minitest'
  gem 'pry-byebug'
end
