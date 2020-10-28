ENV['RACK_ENV'] ||= 'test'
ENV["DATABASE_URL"] ||= 'postgresql://postgres@127.0.0.1:5432/lrus_test'
require 'pry-byebug'
require 'rack/test'
require 'minitest/autorun'
require_relative '../app'

describe App do
  include Rack::Test::Methods

  after do
    PG::Connection.new(ENV["DATABASE_URL"]).tap do |connection|
      response = connection.exec_params "DELETE FROM apps"
      connection.finish
    end
  end

  def app
    App
  end

  describe 'POST /:name' do
    it 'string' do
      post '/foo', branch: 'bar'
      assert last_response.body == 'foo1'
    end

    it 'same' do
      post '/foo', branch: 'bar'
      post '/foo', branch: 'bar'
      assert last_response.body == 'foo1'
    end

    it 'other' do
      post '/foo', branch: 'bar'
      post '/foo', branch: 'baz'
      assert last_response.body == 'foo2'
    end

    it 'same2' do
      post '/foo', branch: 'bar'
      post '/foo', branch: 'baz'
      post '/foo', branch: 'bar'
      assert last_response.body == 'foo1'
    end

    it 'evict' do
      post '/foo', branch: 'foo' # => foo1
      assert last_response.body == 'foo1'

      post '/foo', branch: 'bar' # => foo2
      assert last_response.body == 'foo2'

      post '/foo', branch: 'baz' # => foo3
      assert last_response.body == 'foo3'

      post '/foo', branch: 'qux' # => foo1
      assert last_response.body == 'foo1'

      post '/foo', branch: 'foo' # => foo2
      assert last_response.body == 'foo2'

      post '/foo', branch: 'bar' # => foo3
      assert last_response.body == 'foo3'
    end

    it 'template' do
      post '/foo', branch: 'bar', tmpl: ''
      assert last_response.body == ''

      post '/foo', branch: 'bar', tmpl: 'FOO'
      assert last_response.body == 'FOO'

      post '/foo', branch: 'bar', tmpl: '${name}-${n}-${b}'
      assert last_response.body == 'foo-1-bar'
    end

    it 'lock app server' do
      post '/foo', branch: 'bar' # create new app
      post '/foo/1/lock' # lock all server
      post '/foo/2/lock'
      post '/foo/3/lock'

      post '/foo', branch: 'bar'
      assert last_response.status == 200
      assert last_response.body == 'foo1'

      post '/foo', branch: 'baz' # trying allocate new server
      assert last_response.status == 406
      assert last_response.body == '<h1>Locked</h1>'

      delete '/foo/3/lock' # unlock server3

      post '/foo', branch: 'baz'
      assert last_response.status == 200
      assert last_response.body == 'foo3'

      post '/foo', branch: 'qux'
      assert last_response.status == 200
      assert last_response.body == 'foo3'
    end

    it 'allow /' do
      post '/foo', branch: 'bar/baz/wow'
      assert last_response.status == 200
    end

    it 'explicit number' do
      post '/foo', branch: 'bar'
      assert last_response.status == 200
      assert last_response.body == 'foo1'
      post '/foo', branch: 'bar', number: 2
      assert last_response.status == 200
      assert last_response.body == 'foo2'
    end

    it 'increase' do
      post '/foo', branch: 'foo', size: 3 # => foo1
      post '/foo', branch: 'bar', size: 3 # => foo2
      post '/foo', branch: 'baz', size: 3 # => foo3
      post '/foo', branch: 'qux', size: 4 # => foo4
      assert last_response.body == 'foo4'
    end

    it 'shrink' do
      post '/foo', branch: 'foo', size: 3 # => foo1
      post '/foo', branch: 'bar', size: 3 # => foo2
      post '/foo', branch: 'baz', size: 3 # => foo3
      assert last_response.body == 'foo3'
      post '/foo', branch: 'baz', size: 2 # => foo1
      assert last_response.body == 'foo1'
    end

    it 'empty' do
      post '/foo', branch: 'foo' # => foo1
      post '/foo', branch: 'bar' # => foo2
      post '/foo', branch: 'baz' # => foo3
      post '/foo/2/free'
      post '/foo', branch: 'qux' # => foo2
      assert last_response.body == 'foo2'
    end

    describe 'github webhook' do
      it 'work' do
        post_data = {
          action: 'closed',
          pull_request: {
            head: {
              ref: 'bar'
            }
          }
        }.to_json
        response_header = {
          'HTTP_X_GITHUB_EVENT' => 'pull_request'
        }

        post '/foo', branch: 'bar' # create new app
        post '/foo/1/lock' # lock
        post '/webhook/unlock/foo', post_data, response_header
        assert last_response.status == 200
        assert last_response.body == 'ok'
      end

      it 'not exist app' do
        post_data = {
          action: 'closed',
          pull_request: {
            head: {
              ref: 'bar'
            }
          }
        }.to_json
        response_header = {
          'HTTP_X_GITHUB_EVENT' => 'pull_request'
        }

        post '/foo', branch: 'bar' # create new app
        post '/foo/1/lock' # lock
        post '/webhook/unlock/hoge', post_data, response_header
        assert last_response.status == 200
        assert last_response.body == 'Not exist application: hoge'
      end

      it 'not exist repo' do
        post_data = {
          action: 'closed',
          pull_request: {
            head: {
              ref: 'fuga'
            }
          }
        }.to_json
        response_header = {
          'HTTP_X_GITHUB_EVENT' => 'pull_request'
        }

        post '/foo', branch: 'bar' # create new app
        post '/foo/1/lock' # lock
        post '/webhook/unlock/foo', post_data, response_header
        assert last_response.status == 200
        assert last_response.body == 'Not exist repository: fuga'
      end

      it 'not accepted action' do
        post_data = {
          action: 'opened',
          pull_request: {
            head: {
              ref: 'bar'
            }
          }
        }.to_json
        response_header = {
          'HTTP_X_GITHUB_EVENT' => 'pull_request'
        }

        post '/foo', branch: 'bar' # create new app
        post '/foo/1/lock' # lock
        post '/webhook/unlock/foo', post_data, response_header
        assert last_response.status == 200
        assert last_response.body == 'Not accepted action: opened'
      end

      it 'not accepted event' do
        post_data = {
          action: 'closed',
          pull_request: {
            base: {
              repo: {
                name: 'bar'
              }
            }
          }
        }.to_json
        response_header = {
          'HTTP_X_GITHUB_EVENT' => 'pull_request_review'
        }

        post '/foo', branch: 'bar' # create new app
        post '/foo/1/lock' # lock
        post '/webhook/unlock/foo', post_data, response_header
        assert last_response.status == 200
        assert last_response.body == 'Not accepted event: pull_request_review'
      end
    end
  end
end
