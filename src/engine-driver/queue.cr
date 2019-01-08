require "priority-queue"
require "tasker"
require "json"

class EngineDriver::Queue
  def initialize(@logger : ::Logger)
    @queue = Priority::Queue(Task).new

    # Task defaults
    @priority = 50
    @timeout = 5.seconds
    @retries = 3
    @wait = true

    # Queue controls
    @channel = Channel(Nil).new
    @terminated = false
    @waiting = false
    @online = false

    spawn { process! }
  end

  @current : Task?
  @previous : Task?
  @timeout : Time::Span
  getter :current, :waiting
  getter :online, :logger

  def online=(state : Bool)
    @online = state
    if @online && @waiting && @queue.size > 0
      spawn { @channel.send nil }
    end
  end

  def add(
    priority = @priority,
    timeout = @timeout,
    retries = @retries,
    wait = @wait,
    name = nil,
    &callback : (Task) -> Nil
  )
    task = Task.new(self, callback, priority, timeout, retries, wait, name)

    if @online
      @queue.push priority, task
      # Spawn so the channel send occurs next tick
      spawn { @channel.send nil } if @waiting
    elsif name
      @queue.push priority, task
    end

    # Task returned so response_required! can be called as required
    task
  end

  def terminate
    @terminated = true
    @channel.close
  end

  private def process!
    loop do
      # Wait for a new task to be available
      if @online && @queue.size > 0
        break if @terminated
      else
        @waiting = true
        @channel.receive?
        @waiting = false

        break if @terminated

        # Prevent any race conditions
        # Could be multiple adds before receive returns
        next if !@online || @queue.size <= 0
      end

      # Check if the previous task should effect the current task
      if previous = @previous
        previous.delay_required?
      end

      # Perform tasks
      task = @queue.pop.value
      @current = task
      task.execute!.get

      # Task complete
      @previous = @current
      @current = nil
    end
  end
end
