using System.Globalization;

namespace HappyLulu.Core;

public enum ArrivalSource { Unlock, Manual }
public enum WorkdayMode { Normal, MorningHalf, AfternoonHalf }
public enum UiLanguage { System, Korean, English }
public enum RemainingTimeUnit { HoursMinutes, Milliseconds, Seconds, Minutes, Hours }

public sealed class WorkSettings
{
    public int WorkMinutes { get; set; } = 480;
    public int BreakMinutes { get; set; } = 60;
    public bool IsValid => WorkMinutes is >= 60 and <= 960 && BreakMinutes is >= 0 and <= 240;
    public WorkSettings Copy() => new() { WorkMinutes = WorkMinutes, BreakMinutes = BreakMinutes };
}

public sealed class Arrival
{
    public string Day { get; set; } = "";
    public DateTimeOffset Time { get; set; }
    public ArrivalSource Source { get; set; }
    public WorkdayMode Mode { get; set; }
}

public sealed class AttendanceState
{
    public int Version { get; set; } = 1;
    public WorkSettings Settings { get; set; } = new();
    public Dictionary<string, Arrival> Arrivals { get; set; } = new(StringComparer.Ordinal);
    public HashSet<string> SuppressedDays { get; set; } = new(StringComparer.Ordinal);
    public DateTimeOffset? LastUnlockAt { get; set; }
    public UiLanguage Language { get; set; } = UiLanguage.System;

    public RemainingTimeUnit RemainingTimeUnit { get; set; } = RemainingTimeUnit.HoursMinutes;

    public AttendanceState Copy() => new()
    {
        Version = Version,
        Settings = Settings.Copy(),
        Arrivals = Arrivals.ToDictionary(pair => pair.Key, pair => new Arrival
        {
            Day = pair.Value.Day,
            Time = pair.Value.Time,
            Source = pair.Value.Source,
            Mode = pair.Value.Mode
        }, StringComparer.Ordinal),
        SuppressedDays = new HashSet<string>(SuppressedDays, StringComparer.Ordinal),
        LastUnlockAt = LastUnlockAt,
        Language = Language,
        RemainingTimeUnit = RemainingTimeUnit
    };
}

public readonly record struct OvertimeStatus(int ElapsedMinutes, int MinutesToMealThreshold)
{
    public bool MealThresholdReached => MinutesToMealThreshold == 0;
}

public static class Attendance
{
    public static string DayKey(DateTimeOffset date) =>
        date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    public static Arrival? Today(AttendanceState state, DateTimeOffset now) =>
        state.Arrivals.GetValueOrDefault(DayKey(now));

    public static bool IsAllowed(DateTimeOffset date, WorkdayMode mode)
    {
        int minute = date.Hour * 60 + date.Minute;
        return mode == WorkdayMode.MorningHalf
            ? minute is >= 780 and <= 900
            : minute is >= 480 and <= 600;
    }

    public static WorkdayMode? AutomaticMode(DateTimeOffset date)
    {
        if (IsAllowed(date, WorkdayMode.Normal)) return WorkdayMode.Normal;
        if (IsAllowed(date, WorkdayMode.MorningHalf)) return WorkdayMode.MorningHalf;
        return null;
    }

    // Called only for a Windows SessionUnlock event observed while this process runs.
    public static bool RecordUnlock(AttendanceState state, DateTimeOffset at)
    {
        state.LastUnlockAt = at;
        string day = DayKey(at);
        DateTimeOffset recordedAt = at.Hour is >= 6 and < 8
            ? new DateTimeOffset(at.Year, at.Month, at.Day, 8, 0, 0, at.Offset) : at;
        WorkdayMode? mode = AutomaticMode(recordedAt);
        if (mode is null || state.Arrivals.ContainsKey(day) || state.SuppressedDays.Contains(day))
            return false;
        state.Arrivals[day] = new Arrival { Day = day, Time = recordedAt, Source = ArrivalSource.Unlock, Mode = mode.Value };
        return true;
    }

    public static void SetManual(AttendanceState state, DateTimeOffset at,
                                 DateTimeOffset now, WorkdayMode? selectedMode)
    {
        WorkdayMode? mode = selectedMode ?? AutomaticMode(at);
        if (at > now || DayKey(at) != DayKey(now) || mode is null || !IsAllowed(at, mode.Value))
            throw new ArgumentException("Arrival must be a past time today in the selected work window.");
        string day = DayKey(now);
        state.Arrivals[day] = new Arrival { Day = day, Time = at, Source = ArrivalSource.Manual, Mode = mode.Value };
        state.SuppressedDays.Remove(day);
    }

    public static void SkipToday(AttendanceState state, DateTimeOffset now)
    {
        string day = DayKey(now);
        state.Arrivals.Remove(day);
        state.SuppressedDays.Add(day);
    }

    public static bool IsLastFriday(DateTimeOffset at) =>
        at.DayOfWeek == DayOfWeek.Friday && at.AddDays(7).Month != at.Month;

    public static DateTimeOffset Departure(Arrival arrival, WorkSettings settings)
    {
        if (arrival.Mode != WorkdayMode.Normal) return arrival.Time.AddHours(4);
        int minutes = settings.WorkMinutes + settings.BreakMinutes -
                      (IsLastFriday(arrival.Time) ? 120 : 0);
        return arrival.Time.AddMinutes(Math.Max(0, minutes));
    }

    public static int RemainingMinutes(DateTimeOffset departure, DateTimeOffset now) =>
        Math.Max(0, (int)Math.Ceiling((departure - now).TotalMinutes));

    public static DateTimeOffset MealThresholdAt(Arrival arrival, WorkSettings settings) =>
        Departure(arrival, settings).AddMinutes(120);

    // This is a time guide from planned departure, not evidence of actual work or reimbursement approval.
    public static OvertimeStatus? Overtime(AttendanceState state, DateTimeOffset now)
    {
        string day = DayKey(now);
        if (state.SuppressedDays.Contains(day) || !state.Arrivals.TryGetValue(day, out Arrival? arrival))
            return null;
        DateTimeOffset departure = Departure(arrival, state.Settings);
        if (now < departure) return null;
        int elapsed = (int)Math.Floor((now - departure).TotalMinutes);
        int toMeal = Math.Max(0, (int)Math.Ceiling((MealThresholdAt(arrival, state.Settings) - now).TotalMinutes));
        return new OvertimeStatus(elapsed, toMeal);
    }

    public static double Progress(Arrival arrival, DateTimeOffset departure, DateTimeOffset now)
    {
        double length = (departure - arrival.Time).TotalSeconds;
        return length <= 0 ? (now >= departure ? 1 : 0) :
            Math.Clamp((now - arrival.Time).TotalSeconds / length, 0, 1);
    }
}
