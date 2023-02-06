# BugBunny

This gem simplify use of bunny gem. You can use 2 types of comunitaction, sync and async, Only is necessary define one `Adapter` to publish messages and `Consumer` to consume messages.

# Example

```
# Adapter Code
class TestAdapter < ::BugBunny::Adapter
  def self.publish_and_consume
    service_adapter = TestAdapter.new
    sync_queue = service_adapter.build_queue(:queue_test, durable: true, exclusive: false, auto_delete: false)

    message = ::BugBunny::Message.new(service_action: :test_action, body: { msg: 'test message' })

    service_adapter.publish_and_consume!(message, sync_queue, check_consumers_count: false)

    service_adapter.close_connection! # ensure the adapter is close

    service_adapter.make_response
  end
end

# Controller Code
class TestController < ::BugBunny::Controller
  ##############################################################################
  # SYNC SERVICE ACTIONS
  ##############################################################################
  def self.test_action(message)
    puts 'sleeping 5 seconds...'
    sleep 5
    { status: :success, body: message.body }
  end
end
```



## Installation

TODO: Replace `UPDATE_WITH_YOUR_GEM_NAME_PRIOR_TO_RELEASE_TO_RUBYGEMS_ORG` with your gem name right after releasing it to RubyGems.org. Please do not do it earlier due to security reasons. Alternatively, replace this section with instructions to install your gem from git if you don't plan to release to RubyGems.org.

Install the gem and add to the application's Gemfile by executing:

    $ bundle add UPDATE_WITH_YOUR_GEM_NAME_PRIOR_TO_RELEASE_TO_RUBYGEMS_ORG

If bundler is not being used to manage dependencies, install the gem by executing:

    $ gem install UPDATE_WITH_YOUR_GEM_NAME_PRIOR_TO_RELEASE_TO_RUBYGEMS_ORG

## Usage

TODO: Write usage instructions here

## Development

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/[USERNAME]/bug_bunny.
