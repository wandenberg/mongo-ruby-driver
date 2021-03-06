require 'spec_helper'

describe Mongo::Server::Connection do

  let(:address) do
    default_address
  end

  let(:monitoring) do
    Mongo::Monitoring.new
  end

  let(:listeners) do
    Mongo::Event::Listeners.new
  end

  let(:cluster) do
    double('cluster')
  end

  let(:server) do
    Mongo::Server.new(address, cluster, monitoring, listeners, TEST_OPTIONS)
  end

  let(:pool) do
    double('pool')
  end

  after do
    expect(cluster).to receive(:pool).with(server).and_return(pool)
    expect(pool).to receive(:disconnect!).and_return(true)
    server.disconnect!
  end

  describe '#connectable?' do

    context 'when the connection is not connectable' do

      let(:bad_address) do
        Mongo::Address.new('127.0.0.1:666')
      end

      let(:bad_server) do
        Mongo::Server.new(bad_address, cluster, monitoring, listeners, TEST_OPTIONS)
      end

      let(:connection) do
        described_class.new(bad_server)
      end

      it 'returns false' do
        expect(connection).to_not be_connectable
      end
    end
  end

  describe '#connect!' do

    context 'when no socket exists' do

      let(:connection) do
        described_class.new(server)
      end

      let!(:result) do
        connection.connect!
      end

      let(:socket) do
        connection.send(:socket)
      end

      it 'returns true' do
        expect(result).to be true
      end

      it 'creates a socket' do
        expect(socket).to_not be_nil
      end

      it 'connects the socket' do
        expect(socket).to be_alive
      end
    end

    context 'when a socket exists' do

      let(:connection) do
        described_class.new(server)
      end

      before do
        connection.connect!
        connection.connect!
      end

      let(:socket) do
        connection.send(:socket)
      end

      it 'keeps the socket alive' do
        expect(socket).to be_alive
      end
    end

    context 'when user credentials exist' do

      context 'when the user is not authorized' do

        let(:connection) do
          described_class.new(
            server,
            TEST_OPTIONS.merge(
              :user => 'notauser',
              :password => 'password',
              :database => TEST_DB )
          )
        end

        let!(:error) do
          e = begin; connection.send(:ensure_connected); rescue => ex; ex; end
        end

        it 'raises an error' do
          expect(error).to be_a(Mongo::Auth::Unauthorized)
        end

        it 'disconnects the socket' do
          expect(connection.send(:socket)).to be(nil)
        end

        it 'marks the server as unknown' do
          pending 'Server must be set as unknown'
          expect(server).to be_unknown
        end
      end

      describe 'when the user is authorized' do

        let(:connection) do
          described_class.new(
            server,
            TEST_OPTIONS.merge(
              :user => TEST_USER.name,
              :password => TEST_USER.password,
              :database => TEST_DB )
          )
        end

        before do
          connection.connect!
        end

        it 'sets the connection as connected' do
          expect(connection).to be_connected
        end
      end
    end
  end

  describe '#disconnect!' do

    context 'when a socket is not connected' do

      let(:connection) do
        described_class.new(server)
      end

      it 'does not raise an error' do
        expect(connection.disconnect!).to be true
      end
    end

    context 'when a socket is connected' do

      let(:connection) do
        described_class.new(server)
      end

      before do
        connection.connect!
        connection.disconnect!
      end

      it 'disconnects the socket' do
        expect(connection.send(:socket)).to be_nil
      end
    end
  end

  describe '#dispatch' do

    let!(:connection) do
      described_class.new(
        server,
        TEST_OPTIONS.merge(
          :user => TEST_USER.name,
          :password => TEST_USER.password,
          :database => TEST_DB )
      )
    end

    let(:documents) do
      [{ 'name' => 'testing' }]
    end

    let(:insert) do
      Mongo::Protocol::Insert.new(TEST_DB, TEST_COLL, documents)
    end

    let(:query) do
      Mongo::Protocol::Query.new(TEST_DB, TEST_COLL, { 'name' => 'testing' })
    end

    context 'when providing a single message' do

      let(:reply) do
        connection.dispatch([ insert, query ])
      end

      after do
        authorized_collection.delete_many
      end

      it 'it dispatchs the message to the socket' do
        expect(reply.documents.first['name']).to eq('testing')
      end
    end

    context 'when providing multiple messages' do

      let(:selector) do
        { :getlasterror => 1 }
      end

      let(:command) do
        Mongo::Protocol::Query.new(TEST_DB, '$cmd', selector, :limit => -1)
      end

      let(:reply) do
        connection.dispatch([ insert, command ])
      end

      after do
        authorized_collection.delete_many
      end

      it 'it dispatchs the message to the socket' do
        expect(reply.documents.first['ok']).to eq(1.0)
      end
    end

    context 'when the response_to does not match the request_id' do

      let(:documents) do
        [{ 'name' => 'bob' }, { 'name' => 'alice' }]
      end

      let(:insert) do
        Mongo::Protocol::Insert.new(TEST_DB, TEST_COLL, documents)
      end

      let(:query_bob) do
        Mongo::Protocol::Query.new(TEST_DB, TEST_COLL, { name: 'bob' })
      end

      let(:query_alice) do
        Mongo::Protocol::Query.new(TEST_DB, TEST_COLL, { name: 'alice' })
      end

      after do
        authorized_collection.delete_many
      end

      before do
        # Fake a query for which we did not read the response. See RUBY-1117
        allow(query_bob).to receive(:replyable?) { false }
        connection.dispatch([ insert, query_bob ])
      end

      it 'raises an UnexpectedResponse error' do
        expect {
          connection.dispatch([ query_alice ])
        }.to raise_error(Mongo::Error::UnexpectedResponse,
          /Got response for request ID \d+ but expected response for request ID \d+/)
      end

      it 'does not affect subsequent requests' do
        expect {
          connection.dispatch([ query_alice ])
        }.to raise_error(Mongo::Error::UnexpectedResponse)

        expect(connection.dispatch([ query_alice ]).documents.first['name']).to eq('alice')
      end
    end

    context 'when a request is interrupted (Thread.kill)' do

      let(:documents) do
        [{ 'name' => 'bob' }, { 'name' => 'alice' }]
      end

      let(:insert) do
        Mongo::Protocol::Insert.new(TEST_DB, TEST_COLL, documents)
      end

      let(:query_bob) do
        Mongo::Protocol::Query.new(TEST_DB, TEST_COLL, { name: 'bob' })
      end

      let(:query_alice) do
        Mongo::Protocol::Query.new(TEST_DB, TEST_COLL, { name: 'alice' })
      end

      before do
        connection.dispatch([ insert ])
      end

      after do
        authorized_collection.delete_many
      end

      it 'closes the socket and does not use it for subsequent requests' do
        t = Thread.new {
          # Kill the thread just before the reply is read
          allow(Mongo::Protocol::Reply).to receive(:deserialize_header) { t.kill }
          connection.dispatch([ query_bob ])
        }
        t.join
        allow(Mongo::Protocol::Reply).to receive(:deserialize_header).and_call_original
        expect(connection.dispatch([ query_alice ]).documents.first['name']).to eq('alice')
      end
    end

    context 'when the message exceeds the max size' do

      context 'when the message is an insert' do

        before do
          allow(connection).to receive(:max_message_size).and_return(200)
        end

        let(:documents) do
          [{ 'name' => 'testing' } ] * 10
        end

        let(:reply) do
          connection.dispatch([ insert ])
        end

        it 'checks the size against the max message size' do
          expect {
            reply
          }.to raise_exception(Mongo::Error::MaxMessageSize)
        end
      end

      context 'when the message is a command' do

        before do
          allow(connection).to receive(:max_bson_object_size).and_return(100)
        end

        let(:selector) do
          { :getlasterror => '1' }
        end

        let(:command) do
          Mongo::Protocol::Query.new(TEST_DB, '$cmd', selector, :limit => -1)
        end

        let(:reply) do
          connection.dispatch([ command ])
        end

        it 'checks the size against the max bson size' do
          expect {
            reply
          }.to raise_exception(Mongo::Error::MaxBSONSize)
        end
      end
    end

    context 'when a network or socket error occurs' do

      let(:socket) do
        connection.connect!
        connection.instance_variable_get(:@socket)
      end

      before do
        expect(socket).to receive(:write).and_raise(Mongo::Error::SocketError)
      end

      it 'disconnects and raises the exception' do
        expect {
          connection.dispatch([ insert ])
        }.to raise_error(Mongo::Error::SocketError)
        expect(connection).to_not be_connected
      end
    end

    context 'when the process is forked' do

      let(:insert) do
        Mongo::Protocol::Insert.new(TEST_DB, TEST_COLL, documents)
      end

      before do
        expect(Process).to receive(:pid).at_least(:once).and_return(1)
      end

      after do
        authorized_collection.delete_many
      end

      it 'disconnects the connection' do
        expect(connection).to receive(:disconnect!).and_call_original
        connection.dispatch([ insert ])
      end

      it 'sets a new pid' do
        connection.dispatch([ insert ])
        expect(connection.pid).to eq(1)
      end
    end
  end

  describe '#initialize' do

    context 'when host and port are provided' do

      let(:connection) do
        described_class.new(server)
      end

      it 'sets the address' do
        expect(connection.address).to eq(server.address)
      end

      it 'sets the socket to nil' do
        expect(connection.send(:socket)).to be_nil
      end

      it 'sets the timeout to the default' do
        expect(connection.timeout).to eq(5)
      end
    end

    context 'when timeout options are provided' do

      let(:connection) do
        described_class.new(server, socket_timeout: 10)
      end

      it 'sets the timeout' do
        expect(connection.timeout).to eq(10)
      end
    end

    context 'when ssl options are provided' do

      let(:ssl_options) do
        { :ssl => true, :ssl_key => 'file', :ssl_key_pass_phrase => 'iamaphrase' }
      end

      let(:connection) do
        described_class.new(server, ssl_options)
      end

      it 'sets the ssl options' do
        expect(connection.send(:ssl_options)).to eq(ssl_options)
      end
    end

    context 'when ssl is false' do

      context 'when ssl options are provided' do

        let(:ssl_options) do
          { :ssl => false, :ssl_key => 'file', :ssl_key_pass_phrase => 'iamaphrase' }
        end

        let(:connection) do
          described_class.new(server, ssl_options)
        end

        it 'does not set the ssl options' do
          expect(connection.send(:ssl_options)).to be_empty
        end
      end

      context 'when ssl options are not provided' do

        let(:ssl_options) do
          { :ssl => false }
        end

        let(:connection) do
          described_class.new(server, ssl_options)
        end

        it 'does not set the ssl options' do
          expect(connection.send(:ssl_options)).to be_empty
        end
      end
    end

    context 'when authentication options are provided' do

      let(:connection) do
        described_class.new(
          server,
          :user => TEST_USER.name,
          :password => TEST_USER.password,
          :database => TEST_DB,
          :auth_mech => :mongodb_cr
        )
      end

      let(:user) do
        Mongo::Auth::User.new(
          database: TEST_DB,
          user: TEST_USER.name,
          password: TEST_USER.password
        )
      end

      it 'sets the auth options' do
        expect(connection.options[:user]).to eq(user.name)
      end
    end
  end

  describe '#auth_mechanism' do

    let(:connection) do
      described_class.new(server)
    end

    let(:reply) do
      double('reply').tap do |r|
        allow(r).to receive(:documents).and_return([ ismaster ])
      end
    end

    before do
      connection.connect!
    end

    context 'when the ismaster response indicates the auth mechanism is :scram' do

      let(:ismaster) do
        {
            'maxWireVersion' => 3,
            'minWireVersion' => 0,
            'ok' => 1
        }
      end

      context 'when the server auth mechanism is scram', if: scram_sha_1_enabled? do

        it 'uses scram' do
          socket = connection.instance_variable_get(:@socket)
          max_message_size = connection.send(:max_message_size)
          allow(Mongo::Protocol::Reply).to receive(:deserialize).with(socket, max_message_size).and_return(reply)
          expect(connection.send(:default_mechanism)).to eq(:scram)
        end
      end

      context 'when the server auth mechanism is the default (mongodb_cr)', unless: scram_sha_1_enabled?  do

        it 'uses scram' do
          socket = connection.instance_variable_get(:@socket)
          max_message_size = connection.send(:max_message_size)
          allow(Mongo::Protocol::Reply).to receive(:deserialize).with(socket, max_message_size).and_return(reply)
          expect(connection.send(:default_mechanism)).to eq(:scram)
        end
      end
    end

    context 'when the ismaster response indicates the auth mechanism is :mongodb_cr' do

      let(:ismaster) do
        {
            'maxWireVersion' => 2,
            'minWireVersion' => 0,
            'ok' => 1
        }
      end

      context 'when the server auth mechanism is scram', if: scram_sha_1_enabled? do

        it 'uses scram' do
          socket = connection.instance_variable_get(:@socket)
          max_message_size = connection.send(:max_message_size)
          allow(Mongo::Protocol::Reply).to receive(:deserialize).with(socket, max_message_size).and_return(reply)
          expect(connection.send(:default_mechanism)).to eq(:scram)
        end
      end

      context 'when the server auth mechanism is the default (mongodb_cr)', unless: scram_sha_1_enabled?  do

        it 'uses mongodb_cr' do
          socket = connection.instance_variable_get(:@socket)
          max_message_size = connection.send(:max_message_size)
          allow(Mongo::Protocol::Reply).to receive(:deserialize).with(socket, max_message_size).and_return(reply)
          expect(connection.send(:default_mechanism)).to eq(:mongodb_cr)
        end
      end
    end
  end
end
