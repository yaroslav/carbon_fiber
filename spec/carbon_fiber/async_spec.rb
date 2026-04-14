# frozen_string_literal: true

require "spec_helper"
require "async"
require "async/barrier"
require "async/semaphore"
require "carbon_fiber/async"
require "socket"

RSpec.describe CarbonFiber::Async::Selector, :native_only do
  before { CarbonFiber::Async.default! }

  describe "basic fiber scheduling" do
    it "runs a single Async task to completion" do
      result = nil
      Async { result = 42 }
      expect(result).to eq(42)
    end

    it "runs multiple concurrent tasks" do
      results = []
      Async do
        3.times { |i| Async { results << i } }
      end
      expect(results.sort).to eq([0, 1, 2])
    end

    it "supports sleep inside Async tasks" do
      elapsed = nil
      Async do
        t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        sleep 0.05
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
      end
      expect(elapsed).to be_between(0.03, 0.3)
    end

    it "interleaves sleeping tasks correctly" do
      order = []
      Async do
        Async do
          sleep 0.02
          order << :slow
        end
        Async do
          sleep 0.01
          order << :fast
        end
      end
      expect(order).to eq([:fast, :slow])
    end
  end

  describe "Async::Barrier fan-out" do
    it "waits for all tasks to complete" do
      results = []
      Async do
        barrier = Async::Barrier.new
        5.times { |i| barrier.async { results << i } }
        barrier.wait
      end
      expect(results.sort).to eq([0, 1, 2, 3, 4])
    end
  end

  describe "Async::Semaphore concurrency limiting" do
    it "limits concurrent access to a resource" do
      max_concurrent = 0
      current = 0
      mutex = Mutex.new

      Async do
        semaphore = Async::Semaphore.new(3)
        barrier = Async::Barrier.new
        10.times do
          barrier.async do
            semaphore.acquire do
              mutex.synchronize do
                current += 1
                max_concurrent = [max_concurrent, current].max
              end
              sleep 0.01
              mutex.synchronize { current -= 1 }
            end
          end
        end
        barrier.wait
      end

      expect(max_concurrent).to be <= 3
    end
  end

  describe "TCP networking under Async" do
    def with_loopback_server(response_body = "OK")
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.ip_port
      response = "HTTP/1.1 200 OK\r\nContent-Length: #{response_body.bytesize}\r\nConnection: close\r\n\r\n#{response_body}"

      thread = Thread.new do
        loop do
          conn = server.accept
          conn.sync = true
          Thread.new(conn) do |sock|
            buf = +""
            loop {
              buf << sock.readpartial(4096)
              break if buf.include?("\r\n\r\n")
            }
            sock.write(response)
            sock.close
          rescue IOError, Errno::ECONNRESET
          end
        end
      rescue IOError
      end

      yield port
    ensure
      server&.close
      thread&.join(1)
    end

    it "performs a simple TCP exchange" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.ip_port
      reply = nil

      Thread.new do
        conn = server.accept
        conn.write("pong")
        conn.close
      rescue IOError
      end

      Async do
        socket = TCPSocket.new("127.0.0.1", port)
        socket.write("ping")
        reply = socket.read(4)
        socket.close
      end

      expect(reply).to eq("pong")
    ensure
      server&.close
    end

    it "handles concurrent TCP clients" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.ip_port
      replies = []

      Thread.new do
        3.times do
          conn = server.accept
          conn.sync = true
          data = conn.read(4)
          conn.write(data.reverse)
          conn.close
        rescue IOError
        end
      end

      Async do
        barrier = Async::Barrier.new
        %w[abcd efgh ijkl].each do |word|
          barrier.async do
            socket = TCPSocket.new("127.0.0.1", port)
            socket.write(word)
            replies << socket.read(4)
            socket.close
          end
        end
        barrier.wait
      end

      expect(replies.sort).to eq(%w[dcba hgfe lkji])
    ensure
      server&.close
    end
  end

  describe "Net::HTTP under Async" do
    def with_http_server(body: '{"ok":true}', connection: "close")
      require "net/http"
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.ip_port
      response = "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nContent-Type: application/json\r\nConnection: #{connection}\r\n\r\n#{body}"

      thread = Thread.new do
        loop do
          conn = server.accept
          conn.sync = true
          Thread.new(conn) do |sock|
            loop do
              buf = +""
              loop {
                buf << sock.readpartial(4096)
                break if buf.include?("\r\n\r\n")
              }
              sock.write(response)
              break if connection == "close"
            end
          rescue IOError, Errno::ECONNRESET, Errno::EPIPE
          ensure
            begin
              sock.close
            rescue
              nil
            end
          end
        end
      rescue IOError
      end

      yield port
    ensure
      server&.close
      thread&.join(1)
    end

    it "completes a single HTTP request" do
      with_http_server do |port|
        response = nil
        Async do
          response = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/"))
        end
        expect(response.code).to eq("200")
        expect(response.body).to eq('{"ok":true}')
      end
    end

    it "completes multiple HTTP requests with keep-alive" do
      with_http_server(connection: "keep-alive") do |port|
        responses = []
        Async do
          Net::HTTP.start("127.0.0.1", port, nil, nil) do |http|
            3.times do
              r = http.request(Net::HTTP::Get.new("/"))
              responses << r.code
            end
          end
        end
        expect(responses).to eq(%w[200 200 200])
      end
    end

    it "handles concurrent HTTP clients with keep-alive" do
      with_http_server(connection: "keep-alive") do |port|
        responses = []
        mutex = Mutex.new
        Async do
          barrier = Async::Barrier.new
          5.times do
            barrier.async do
              Net::HTTP.start("127.0.0.1", port, nil, nil) do |http|
                3.times do
                  r = http.request(Net::HTTP::Get.new("/"))
                  mutex.synchronize { responses << r.code }
                end
              end
            end
          end
          barrier.wait
        end
        expect(responses.size).to eq(15)
        expect(responses).to all(eq("200"))
      end
    end
  end

  describe "io_wait correctness" do
    it "does not return stale readability after data is consumed" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.ip_port

      Thread.new do
        conn = server.accept
        conn.sync = true
        buf = +""
        loop {
          buf << conn.readpartial(4096)
          break if buf.include?("\r\n\r\n")
        }
        conn.write("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")
        sleep 5
        conn.close
      rescue IOError
      end

      result = nil
      Async do
        socket = TCPSocket.new("127.0.0.1", port)
        socket.write("GET / HTTP/1.1\r\nHost: test\r\n\r\n")

        # Read entire response
        data = +""
        loop do
          chunk = socket.readpartial(4096)
          data << chunk
          break if data.include?("\r\n\r\n") && data.split("\r\n\r\n", 2).last.bytesize >= 5
        end

        # After consuming all data, socket should NOT report readable
        result = socket.wait_readable(0)
        socket.close
      end

      expect(result).to be_nil
    ensure
      server&.close
    end
  end

  describe "io_read and io_write" do
    it "reads from a pipe via the selector" do
      rd, wr = IO.pipe
      received = nil

      Async do
        Async { received = rd.read(5) }
        Async do
          wr.write("hello")
          wr.close
        end
      end

      expect(received).to eq("hello")
    ensure
      begin
        rd&.close
      rescue
        nil
      end
      begin
        wr&.close
      rescue
        nil
      end
    end

    it "handles large reads across multiple chunks" do
      rd, wr = IO.pipe
      payload = "x" * 65536
      received = nil

      Async do
        Async { received = rd.read(payload.bytesize) }
        Async do
          wr.write(payload)
          wr.close
        end
      end

      expect(received&.bytesize).to eq(payload.bytesize)
    ensure
      begin
        rd&.close
      rescue
        nil
      end
      begin
        wr&.close
      rescue
        nil
      end
    end
  end

  describe "io_close" do
    it "unblocks a fiber waiting on a closed IO" do
      rd, wr = IO.pipe
      error = nil

      Async do
        Async do
          rd.read(1)
        rescue IOError => e
          error = e
        end
        Async { rd.close }
      end

      expect(error).to be_a(IOError)
    ensure
      begin
        wr&.close
      rescue
        nil
      end
    end
  end

  describe "process_wait" do
    it "waits for a child process to finish" do
      status = nil
      Async do
        pid = Process.spawn("true")
        status = Process::Status.wait(pid)
      end
      expect(status).to be_success
    end
  end

  describe "cross-thread unblock" do
    it "resumes a fiber from a background thread" do
      result = nil
      Async do
        result = Thread.new { 42 }.value
      end
      expect(result).to eq(42)
    end
  end

  describe "selector registration" do
    it "registers as IO::Event::Selector::CarbonFiberSelector" do
      expect(IO::Event::Selector::CarbonFiberSelector).to eq(CarbonFiber::Async::Selector)
    end
  end
end
