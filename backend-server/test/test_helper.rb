require 'minitest/autorun'

class FakeResult
  include Enumerable

  def initialize(rows)
    @rows = rows
  end

  def ntuples
    @rows.length
  end

  def each(&block)
    @rows.each(&block)
  end

  def [](index)
    @rows[index]
  end

  def map(&block)
    @rows.map(&block)
  end
end

class FakeDB
  def initialize
    @profiles_by_user = {}
  end

  def set_profiles(user_id, rows)
    @profiles_by_user[user_id.to_i] = rows
  end

  def exec_params(query, params)
    if query.include?('SELECT key_pair')
      user_id = params[0].to_i
      return FakeResult.new(@profiles_by_user[user_id] || [])
    end

    FakeResult.new([])
  end

  def transaction
    yield self
  end
end
