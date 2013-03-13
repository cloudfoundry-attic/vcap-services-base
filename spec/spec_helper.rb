def with_env(changes, &blk)
  old_env = ENV.to_hash
  ENV.update(changes)
  blk.yield
ensure
  ENV.replace(old_env)
end

RSpec::Matchers.define :json_match do |matcher|
  # RSpec matcher?
  if matcher.respond_to?(:matches?)
    match do |json|
      actual = Yajl::Parser.parse(json)
      matcher.matches?(actual)
    end
    # regular values or RSpec Mocks argument matchers
  else
    match do |json|
      actual = Yajl::Parser.parse(json)
      matcher == actual
    end
  end
end
