# vim:fileencoding=utf-8
require_relative 'test_helper'

require_relative 'server/test_helper'

context 'on GET to /schedule' do
  setup { get '/schedule' }

  test('is 200') { assert last_response.ok? }
end

context 'on GET to /schedule with scheduled jobs' do
  setup do
    Resque::Scheduler.env = 'production'
    Resque.schedule = {
      'some_ivar_job' => {
        'cron' => '* * * * *',
        'class' => 'SomeIvarJob',
        'args' => '/tmp',
        'rails_env' => 'production'
      },
      'some_other_job' => {
        'every' => ['1m', ['1h']],
        'queue' => 'high',
        'custom_job_class' => 'SomeOtherJob',
        'args' => {
          'b' => 'blah'
        }
      },
      'some_fancy_job' => {
        'every' => ['1m'],
        'queue' => 'fancy',
        'class' => 'SomeFancyJob',
        'args' => 'sparkles',
        'rails_env' => 'fancy'
      },
      'shared_env_job' => {
        'cron' => '* * * * *',
        'class' => 'SomeSharedEnvJob',
        'args' => '/tmp',
        'rails_env' => 'fancy, production'
      }
    }
    Resque::Scheduler.load_schedule!
    get '/schedule'
  end

  test('is 200') { assert last_response.ok? }

  test 'see the scheduled job' do
    assert last_response.body.include?('SomeIvarJob')
  end

  test 'include(highlight) jobs for other envs' do
    assert last_response.body.include?('SomeFancyJob')
  end

  test 'includes job used in multiple environments' do
    assert last_response.body.include?('SomeSharedEnvJob')
  end

  test 'allows delete when dynamic' do
    Resque::Scheduler.stubs(:dynamic).returns(true)
    get '/schedule'

    assert last_response.body.include?('Delete')
  end

  test "doesn't allow delete when static" do
    Resque::Scheduler.stubs(:dynamic).returns(false)
    get '/schedule'

    assert !last_response.body.include?('Delete')
  end
end

context 'on GET to /delayed' do
  [
    {
      'class' => SomeIvarJob,
      'args' => %w(foo bar),
      't' => 3600
    },
    {
      'class' => SomeFancyJob,
      'args' => [],
      't' => 30
    },
    {
      'class' => FakePHPClass,
      'args' => %w(1 10 100),
      't' => 36_000
    }
  ].each do |job|
    test "is 200 with class #{job['class']}" do
      Resque.enqueue_at(Time.now + job['t'], job['class'], *job['args'])
      get '/delayed'
      assert last_response.ok?
    end

    test "contains link to all schedules for class #{job['class']}" do
      Resque.enqueue_at(Time.now + job['t'], job['class'], *job['args'])
      get '/delayed'
      assert !(last_response.body =~ %r{/delayed/jobs/#{CGI.escape(job['class'].to_s)}}).nil?
    end
  end
end

context 'on GET to /delayed/jobs/:klass' do
  setup do
    @t = Time.now + 3600
    Resque.enqueue_at(@t, SomeIvarJob, 'foo', 'bar')
    get(
      URI('/delayed/jobs/SomeIvarJob?args=' <<
          CGI.escape(%w(foo bar).to_json)).to_s
    )
  end

  test('is 200') { assert last_response.ok? }

  test 'see the scheduled job' do
    assert last_response.body.include?(@t.to_s)
  end

  context 'with a namespaced class' do
    setup do
      @t = Time.now + 3600
      module Foo
        class Bar
          def self.queue
            'bar'
          end
        end
      end
      Resque.enqueue_at(@t, Foo::Bar, 'foo', 'bar')
      get(
        URI('/delayed/jobs/Foo::Bar?args=' <<
            CGI.escape(%w(foo bar).to_json)).to_s
      )
    end

    test('is 200') { assert last_response.ok? }

    test 'see the scheduled job' do
      assert last_response.body.include?(@t.to_s)
    end
  end
end

module Test
  RESQUE_SCHEDULE = {
    'job_without_params' => {
      'cron' => '* * * * *',
      'class' => 'JobWithoutParams',
      'args' => {
        'host' => 'localhost'
      },
      'rails_env' => 'production'
    },
    'job_with_params' => {
      'every' => '1m',
      'class' => 'JobWithParams',
      'args' => {
        'host' => 'localhost'
      },
      'parameters' => {
        'log_level' => {
          'description' => 'The level of logging',
          'default' => 'warn'
        }
      }
    }
  }.freeze
end

context 'POST /schedule/requeue' do
  setup do
    Resque.schedule = Test::RESQUE_SCHEDULE
    Resque::Scheduler.load_schedule!
  end

  test 'job without params' do
    # Regular jobs without params should redirect to /overview
    job_name = 'job_without_params'
    Resque::Scheduler.stubs(:enqueue_from_config)
                     .once.with(Resque.schedule[job_name])

    post '/schedule/requeue', 'job_name' => job_name
    follow_redirect!
    assert_equal 'http://example.org/overview', last_request.url
    assert last_response.ok?
  end

  test 'job with params' do
    # If a job has params defined,
    # it should render the template with a form for the job params
    job_name = 'job_with_params'
    post '/schedule/requeue', 'job_name' => job_name

    assert last_response.ok?, last_response.errors
    assert last_response.body.include?('This job requires parameters')
    assert last_response.body.include?(
      %(<input type="hidden" name="job_name" value="#{job_name}">)
    )

    Resque.schedule[job_name]['parameters'].each do |_param_name, param_config|
      assert last_response.body.include?(
        '<span style="border-bottom:1px dotted;" ' <<
        %[title="#{param_config['description']}">(?)</span>]
      )
      assert last_response.body.include?(
        '<input type="text" name="log_level" ' <<
        %(value="#{param_config['default']}">)
      )
    end
  end
end

context 'POST /schedule/requeue_with_params' do
  setup do
    Resque.schedule = Test::RESQUE_SCHEDULE
    Resque::Scheduler.load_schedule!
  end

  test 'job with params' do
    job_name = 'job_with_params'
    log_level = 'error'

    job_config = Resque.schedule[job_name]
    args = job_config['args'].merge('log_level' => log_level)
    job_config = job_config.merge('args' => args)

    Resque::Scheduler.stubs(:enqueue_from_config).once.with(job_config)

    post '/schedule/requeue_with_params',
         'job_name' => job_name,
         'log_level' => log_level

    follow_redirect!
    assert_equal 'http://example.org/overview', last_request.url

    assert last_response.ok?, last_response.errors
  end
end

context 'on POST to /delayed/search' do
  setup do
    t = Time.now + 60
    Resque.enqueue_at(t, SomeIvarJob, 'string arg')
    Resque.enqueue(SomeQuickJob)
  end

  test 'should find matching scheduled job' do
    post '/delayed/search', 'search' => 'ivar'
    assert last_response.status == 200
    assert last_response.body.include?('SomeIvarJob')
  end

  test 'the form should encode string params' do
    post '/delayed/search', 'search' => 'ivar'
    assert_match('value="[&quot;string arg&quot;]', last_response.body)
  end

  test 'should find matching queued job' do
    post '/delayed/search', 'search' => 'quick'
    assert last_response.status == 200
    assert last_response.body.include?('SomeQuickJob')
  end

  test 'should escape XSS attempt' do
    post '/delayed/search', 'search' => '"><script>alert(document.cookie);</script>"'
    assert !last_response.body.include?('<script>alert(document.cookie);</script>')
  end
end

context 'on POST to /delayed/cancel_now' do
  setup do
    Resque.reset_delayed_queue
    Resque.enqueue_at(Time.now + 10, SomeIvarJob, 'arg')
    Resque.enqueue_at(Time.now + 100, SomeQuickJob)
  end

  test 'removes the specified job' do
    job_timestamp, *remaining = Resque.delayed_queue_peek(0, 10)
    assert_equal 1, remaining.size

    post '/delayed/cancel_now',
         'timestamp' => job_timestamp,
         'klass'     => SomeIvarJob.name,
         'args'      => Resque.encode(['arg'])

    assert_equal 302, last_response.status
    assert_equal remaining, Resque.delayed_queue_peek(0, 10)
  end

  test 'does not remove the job if the params do not match' do
    timestamps = Resque.delayed_queue_peek(0, 10)

    post '/delayed/cancel_now',
         'timestamp' => timestamps.first,
         'klass'     => SomeIvarJob.name

    assert_equal 302, last_response.status
    assert_equal timestamps, Resque.delayed_queue_peek(0, 10)
  end

  test 'redirects to overview' do
    post '/delayed/cancel_now'
    assert last_response.status == 302
    assert last_response.location.include? '/delayed'
  end
end

context 'on POST to /delayed/clear' do
  setup { post '/delayed/clear' }

  test 'redirects to delayed' do
    assert last_response.status == 302
    assert last_response.location.include? '/delayed'
  end
end

context 'on POST to /delayed/queue_now' do
  setup { post '/delayed/queue_now', timestamp: 0 }

  test 'returns ok status' do
    assert last_response.status == 200
  end
end

context 'on GET to /delayed/:timestamp' do
  setup { get '/delayed/1234567890' }

  test 'shows delayed_timestamp view' do
    assert last_response.status == 200
  end
end

context 'DELETE /schedule when dynamic' do
  setup do
    Resque.schedule = Test::RESQUE_SCHEDULE
    Resque::Scheduler.load_schedule!
    Resque::Scheduler.stubs(:dynamic).returns(true)
  end

  test 'redirects to schedule page' do
    delete '/schedule', job_name: 'job_with_params'

    status = last_response.status
    redirect_location = last_response.original_headers['Location']
    response_status_msg = "Expected response to be a 302, but was a #{status}."
    redirect_msg = "Redirect to #{redirect_location} instead of /schedule."

    assert status == 302, response_status_msg
    assert_match %r{/schedule/?$}, redirect_location, redirect_msg
  end

  test 'does not show the deleted job' do
    delete '/schedule', job_name: 'job_with_params'
    follow_redirect!

    msg = 'The job should not have been shown on the /schedule page.'
    assert !last_response.body.include?('job_with_params'), msg
  end

  test 'removes job from redis' do
    delete '/schedule', job_name: 'job_with_params'

    msg = 'The job was not deleted from redis.'
    assert_nil Resque.fetch_schedule('job_with_params'), msg
  end
end

context 'DELETE /schedule when static' do
  setup do
    Resque.schedule = Test::RESQUE_SCHEDULE
    Resque::Scheduler.load_schedule!
    Resque::Scheduler.stubs(:dynamic).returns(false)
  end

  test 'does not remove the job from the UI' do
    delete '/schedule', job_name: 'job_with_params'
    follow_redirect!

    msg = 'The job should not have been removed from the /schedule page.'
    assert last_response.body.include?('job_with_params'), msg
  end

  test 'does not remove job from redis' do
    delete '/schedule', job_name: 'job_with_params'

    msg = 'The job should not have been deleted from redis.'
    assert Resque.fetch_schedule('job_with_params'), msg
  end
end
