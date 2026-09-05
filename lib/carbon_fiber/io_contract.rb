# frozen_string_literal: true

module CarbonFiber
  # Ruby 4.1 (ruby/ruby#18483) reordered the buffered scheduler hooks to
  # +io_read(io, buffer, offset, length)+ and made them single-transfer:
  # one nonblocking attempt, short results returned directly, -EAGAIN
  # instead of waiting, and zero length returns 0 without I/O.
  # +IO::Buffer::VERSION >= 3+ signals the new contract; Ruby 3.4 through
  # 4.0 define no such constant.
  #
  # @return [Boolean] whether this Ruby uses the v4 scheduler I/O contract
  def self.io_contract_v4?
    defined?(IO::Buffer::VERSION) ? IO::Buffer::VERSION.to_i >= 3 : false
  end
end
