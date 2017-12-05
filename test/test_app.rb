ENV['RACK_ENV'] ||= 'test'
ENV['MONGOLAB_URI'] = 'mongodb://localhost:27017/lrus-test'
require 'minitest/autorun'
require_relative '../app'

describe App do
  include Rack::Test::Methods

  after do
    MONGO.collections.each(&:drop)
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
      post '/foo', branch: 'bar' # => foo2
      post '/foo', branch: 'baz' # => foo3
      post '/foo', branch: 'qux' # => foo1
      assert last_response.body == 'foo1'
      post '/foo', branch: 'foo' # => foo2
      assert last_response.body == 'foo2'
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

    describe 'github webhook' do
      it 'work' do
        post_data = {
          payload: {
            action: 'closed',
            pull_request: {
              base: {
                repo: {
                  name: 'bar'
                }
              }
            }
          }
        }
        response_header = {
          'X-GitHub-Event' => 'pull_request'
        }

        post '/foo', branch: 'bar' # create new app
        post '/foo/1/lock' # lock
        post '/webhook/unlock/foo', post_data, response_header
        assert last_response.status == 200
        assert last_response.body == 'ok'
      end

      it 'not exist app' do
        post_data = {
          payload: {
            action: 'closed',
            pull_request: {
              base: {
                repo: {
                  name: 'bar'
                }
              }
            }
          }
        }
        response_header = {
          'X-GitHub-Event' => 'pull_request'
        }

        post '/foo', branch: 'bar' # create new app
        post '/foo/1/lock' # lock
        post '/webhook/unlock/hoge', post_data, response_header
        assert last_response.status == 200
        assert last_response.body == 'ok'
      end

      it 'not exist repo' do
        post_data = {
          payload: {
            action: 'closed',
            pull_request: {
              base: {
                repo: {
                  name: 'fuga'
                }
              }
            }
          }
        }
        response_header = {
          'X-GitHub-Event' => 'pull_request'
        }

        post '/foo', branch: 'bar' # create new app
        post '/foo/1/lock' # lock
        post '/webhook/unlock/foo', post_data, response_header
        assert last_response.status == 200
        assert last_response.body == 'ok'
      end

      it 'not accepted action' do
        post_data = {
          payload: {
            action: 'opened',
            pull_request: {
              base: {
                repo: {
                  name: 'bar'
                }
              }
            }
          }
        }
        response_header = {
          'X-GitHub-Event' => 'pull_request'
        }

        post '/foo', branch: 'bar' # create new app
        post '/foo/1/lock' # lock
        post '/webhook/unlock/foo', post_data, response_header
        assert last_response.status == 200
        assert last_response.body == 'ok'
      end

      it 'not accepted event' do
        post_data = {
          payload: {
            action: 'closed',
            pull_request: {
              base: {
                repo: {
                  name: 'bar'
                }
              }
            }
          }
        }
        response_header = {
          'X-GitHub-Event' => 'pull_request_review'
        }

        post '/foo', branch: 'bar' # create new app
        post '/foo/1/lock' # lock
        post '/webhook/unlock/foo', post_data, response_header
        assert last_response.status == 200
        assert last_response.body == 'ok'
      end
    end
  end
end
