// The fixtures use one runner slot and advance its one-shot timer explicitly.
internal sealed class RunnerClock : TimeProvider
{
    private readonly Lock gate = new();
    private long ticks;
    private long advanceAfterRead;
    private ScheduledCallback? pending;

    public override long TimestampFrequency => TimeSpan.TicksPerSecond;

    public override long GetTimestamp()
    {
        lock (gate)
        {
            var timestamp = ticks;
            ticks += advanceAfterRead;
            advanceAfterRead = 0;
            return timestamp;
        }
    }

    internal bool HasPendingTimer
    {
        get { lock (gate) return pending is not null; }
    }

    internal void AdvanceAfterNextTimestamp(TimeSpan elapsed)
    {
        lock (gate) advanceAfterRead = elapsed.Ticks;
    }

    internal void Advance(TimeSpan elapsed)
    {
        ScheduledCallback? due = null;
        lock (gate)
        {
            ticks += elapsed.Ticks;
            if (pending is { } timer && timer.Deadline <= ticks)
            {
                due = timer;
                pending = null;
            }
        }
        due?.Callback(due.State);
    }

    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
    {
        lock (gate)
        {
            if (pending is not null || period != Timeout.InfiniteTimeSpan)
                throw new InvalidOperationException("Expected one one-shot runner timer.");
            pending = new ScheduledCallback(ticks + dueTime.Ticks, callback, state);
            return new Delay(this, pending);
        }
    }

    private sealed record ScheduledCallback(long Deadline, TimerCallback Callback, object? State);

    private sealed class Delay(RunnerClock clock, ScheduledCallback timer) : ITimer
    {
        public bool Change(TimeSpan dueTime, TimeSpan period) => throw new NotSupportedException();
        public void Dispose()
        {
            lock (clock.gate)
            {
                if (ReferenceEquals(clock.pending, timer)) clock.pending = null;
            }
        }
        public ValueTask DisposeAsync()
        {
            Dispose();
            return ValueTask.CompletedTask;
        }
    }
}
