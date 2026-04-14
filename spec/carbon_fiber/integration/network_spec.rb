# frozen_string_literal: true

require "spec_helper"
require "socket"

RSpec.describe CarbonFiber::Scheduler do
  include_context "with scheduler"

  describe "with TCP networking" do
    describe "an echo server and a single client" do
      it "exchanges a line of text between two fibers" do
        server = TCPServer.new("127.0.0.1", 0)
        port = server.addr[1]
        reply = nil

        Fiber.schedule do
          client = server.accept
          line = client.gets
          client.puts line.chomp.upcase
          client.close
        end

        Fiber.schedule do
          conn = TCPSocket.new("127.0.0.1", port)
          conn.puts "hello"
          reply = conn.gets
          conn.close
        end

        scheduler.run
        expect(reply.chomp).to eq("HELLO")
      ensure
        begin
          server.close
        rescue
          nil
        end
      end
    end

    describe "an echo server handling multiple concurrent clients" do
      it "responds to all clients without serialising them" do
        server = TCPServer.new("127.0.0.1", 0)
        port = server.addr[1]
        replies = []

        3.times do
          Fiber.schedule do
            client = server.accept
            line = client.gets
            client.puts line.chomp.reverse
            client.close
          end
        end

        %w[abc def ghi].each do |word|
          Fiber.schedule do
            conn = TCPSocket.new("127.0.0.1", port)
            conn.puts word
            replies << conn.gets.chomp
            conn.close
          end
        end

        scheduler.run
        expect(replies).to contain_exactly("cba", "fed", "ihg")
      ensure
        begin
          server.close
        rescue
          nil
        end
      end
    end

    describe "many idle connections with periodic ping/pong" do
      it "exchanges ping/pong on all connections without any of them starving" do
        # Mirrors the websocket_idle benchmark: N connections each sleeping between
        # rounds of sends/receives, testing sleep + TCP I/O interleaved at scale.
        conn_count = 10
        rounds = 5
        server = TCPServer.new("127.0.0.1", 0)
        port = server.addr[1]
        pongs = Array.new(conn_count, 0)

        Fiber.schedule do
          conn_count.times do
            client = server.accept
            Fiber.schedule do
              rounds.times do
                client.read(4)
                client.write("pong")
              end
              client.close
            end
          end
        end

        conn_count.times do |i|
          Fiber.schedule do
            conn = TCPSocket.new("127.0.0.1", port)
            rounds.times do
              sleep 0.002
              conn.write("ping")
              conn.read(4)
              pongs[i] += 1
            end
            conn.close
          end
        end

        scheduler.run
        expect(pongs).to all(eq(rounds))
      ensure
        begin
          server.close
        rescue
          nil
        end
      end
    end

    describe "reading from a socket with a select timeout" do
      it "returns nil when no data arrives within the window" do
        server = TCPServer.new("127.0.0.1", 0)
        port = server.addr[1]
        result = :not_set

        Fiber.schedule do
          conn = TCPSocket.new("127.0.0.1", port)
          result = IO.select([conn], nil, nil, 0.03)
          conn.close
        end

        # Accept but never write, so the client's select times out.
        Fiber.schedule do
          client = server.accept
          sleep 0.5
          client.close
        end

        scheduler.run
        expect(result).to be_nil
      ensure
        begin
          server.close
        rescue
          nil
        end
      end
    end
  end
end
