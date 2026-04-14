# frozen_string_literal: true

module Bench
  module Workloads
    module SocketHelpers
      private

      def read_exact(io, expected_bytes)
        buffer = +""
        while buffer.bytesize < expected_bytes
          buffer << io.readpartial(expected_bytes - buffer.bytesize)
        end
        buffer
      end

      def write_all(io, payload)
        written = 0
        while written < payload.bytesize
          written += io.write(payload.byteslice(written..))
        end
      end

      def close_socket(io)
        io.close unless io.closed?
      rescue
      end
    end
  end
end
