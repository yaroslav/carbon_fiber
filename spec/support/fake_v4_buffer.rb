# frozen_string_literal: true

# Records Ruby 4.1+ (io, offset, length) buffer calls; results are served
# from a queue. Stands in for IO::Buffer in v4-contract fallback tests on
# Rubies whose real IO::Buffer still uses the legacy (io, length, offset)
# argument order.
class FakeV4Buffer
  attr_reader :calls

  def initialize(*results)
    @results = results
    @calls = []
  end

  def read(io, offset, length)
    @calls << [:read, io, offset, length]
    @results.shift
  end

  def write(io, offset, length)
    @calls << [:write, io, offset, length]
    @results.shift
  end
end
