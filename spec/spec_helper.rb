# frozen_string_literal: true

require 'logger'

begin
  require 'pry-byebug'
rescue LoadError
  nil
end

LOGGER = Logger.new($stdout, level: :debug)

class WatchRun
  TMP_DIR = File.join(__dir__, 'tmp')

  attr_reader :filename

  def initialize(filename:, action:, directory:)
    @filename =
      filename =~ %r{^(/|~|[A-Z]:)} ? filename : File.join(TMP_DIR, filename)
    @directory = directory
    @action = action
    LOGGER.debug "action = #{action}"
  end

  def start
    LOGGER.debug 'start'
    File.write(@filename, 'content1') unless @action == :create
  end

  def run
    start

    make_changes

    wait 0.5

    stop
  end

  def stop
    LOGGER.debug 'stop'
    FileUtils.rm_r(@filename) if File.exist?(@filename)
  end

  private

  def make_changes
    LOGGER.debug "make changes, @filename = #{@filename}"
    if @action == :delete
      FileUtils.remove(@filename)
    elsif @directory
      FileUtils.mkdir_p(@filename)
    else
      File.write(@filename, 'content2')
    end
  end

  MIN_WAIT_SECONDS = 1

  def wait(seconds, interval)
    interval *= 1.5 if ENV['CI']
    # interval *= 1.5 if RUBY_PLATFORM == 'java'
    interval *= 1.5 if Gem::Platform.local.os == 'darwin'
    seconds ||= [interval * 2, MIN_WAIT_SECONDS].max
    max_count = seconds / interval
    count = 0
    while count < max_count && !(block_given? && yield)
      LOGGER.debug "sleep interval #{interval}"
      sleep interval
      count += 1
    end
  end
end

class RubyWatchRun < WatchRun
  attr_reader :filewatcher, :thread, :watched, :processed

  def initialize(filewatcher:, **args)
    super(**args)
    @filewatcher = filewatcher
  end

  def start
    super
    @thread = thread_initialize
    # thread needs a chance to start
    wait 0.5
    wait do
      keep_watching = filewatcher.keep_watching
      LOGGER.debug "keep_watching = #{keep_watching}"
      keep_watching
    end
  end

  def stop
    thread.exit

    wait do
      thread.stop?
    end

    super
  end

  def wait(seconds = nil)
    super seconds, filewatcher.interval
  end

  private

  def make_changes
    super

    # Some OS, filesystems and Ruby interpretators
    # doesn't catch milliseconds of `File.mtime`
    wait do
      LOGGER.debug "processed = #{processed}"
      processed.any?
    end
  end

  def thread_initialize
    @watched ||= 0
    Thread.new(@filewatcher, @processed = []) do |filewatcher, processed|
      LOGGER.debug 'filewatcher watch'
      filewatcher.watch do |filename, event|
        LOGGER.debug "watch: filename = #{filename}, event = #{event}"
        increment_watched
        processed.push([filename, event])
      end
    end
  end

  def increment_watched
    @watched += 1
  end
end

class ShellWatchRun < WatchRun
  EXECUTABLE = "#{'ruby ' if Gem.win_platform?}" \
    "#{File.realpath File.join(__dir__, '..', 'bin', 'filewatcher')}".freeze

  ENV_FILE = File.join(TMP_DIR, 'env')

  def initialize(options:, dumper:, **args)
    super(**args)
    @options = options
    @options[:interval] ||= 0.2
    @options_string =
      @options.map { |key, value| "--#{key}=#{value}" }.join(' ')
    LOGGER.debug "options = #{@options_string}"
    @dumper = dumper
    LOGGER.debug "dumper = #{@dumper}"
  end

  def start
    super

    @pid = spawn_filewatcher

    Process.detach(@pid)

    wait 0.5

    wait do
      LOGGER.debug "pid state = #{pid_state}"
      LOGGER.debug "File.exist?(ENV_FILE) = #{File.exist?(ENV_FILE)}"
      pid_state == 'S' && (!@options[:immediate] || File.exist?(ENV_FILE))
    end
  end

  def stop
    kill_filewatcher

    wait do
      pid_state.empty?
    end

    super
  end

  private

  SPAWN_OPTIONS = Gem.win_platform? ? {} : { pgroup: true }

  def spawn_filewatcher
    spawn_command = "#{EXECUTABLE} #{@options_string} \"#{@filename}\"" \
      " \"ruby #{File.join(__dir__, "dumpers/#{@dumper}_dumper.rb")}\""
    LOGGER.debug "spawn_command = #{spawn_command}"
    spawn spawn_command, **SPAWN_OPTIONS
  end

  def make_changes
    super

    wait do
      LOGGER.debug "File.exist?(ENV_FILE) = #{File.exist?(ENV_FILE)}"
      File.exist?(ENV_FILE)
    end
  end

  def kill_filewatcher
    if Gem.win_platform?
      Process.kill('KILL', @pid)
    else
      ## Problems: https://github.com/thomasfl/filewatcher/pull/83
      ## Solution: https://stackoverflow.com/a/45032252/2630849
      Process.kill('TERM', -Process.getpgid(@pid))
      Process.waitall
    end
    wait
  end

  def pid_state
    ## For macOS output:
    ## https://travis-ci.org/thomasfl/filewatcher/jobs/304433538
    `ps -ho state -p #{@pid}`.sub('STAT', '').strip
  end

  def wait(seconds = nil)
    super seconds, @options[:interval]
  end
end

def dump_to_env_file(content)
  File.write File.join(ShellWatchRun::ENV_FILE), content
end

## For case when required from dumpers
if Object.const_defined?(:RSpec)
  RSpec::Matchers.define :include_all_files do |expected|
    match do |actual|
      expected.all? { |file| actual.include? File.expand_path(file) }
    end
  end
end
