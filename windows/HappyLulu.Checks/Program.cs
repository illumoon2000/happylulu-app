using System.Globalization;
using HappyLulu.Core;

int checks = 0;
void Check(bool condition, string name)
{
    if (!condition) throw new Exception($"FAIL: {name}");
    checks++;
}

DateTimeOffset At(int year, int month, int day, int hour, int minute) =>
    new(year, month, day, hour, minute, 0, TimeSpan.FromHours(9));

foreach (var sample in new[] {
    (Hour: 5, Minute: 59, Second: 59, Expected: (DateTimeOffset?)null),
    (Hour: 6, Minute: 0, Second: 0, Expected: (DateTimeOffset?)At(2026, 10, 23, 8, 0)),
    (Hour: 7, Minute: 59, Second: 59, Expected: (DateTimeOffset?)At(2026, 10, 23, 8, 0)),
    (Hour: 8, Minute: 0, Second: 0, Expected: (DateTimeOffset?)At(2026, 10, 23, 8, 0)),
    (Hour: 9, Minute: 12, Second: 30, Expected: (DateTimeOffset?)At(2026, 10, 23, 9, 12).AddSeconds(30)) })
{
    var earlyState = new AttendanceState();
    var observed = At(2026, 10, 23, sample.Hour, sample.Minute).AddSeconds(sample.Second);
    Check(Attendance.RecordUnlock(earlyState, observed) == (sample.Expected is not null), "early unlock eligibility: " + observed);
    Check(Attendance.Today(earlyState, observed)?.Time == sample.Expected, "normalized early arrival: " + observed);
    Check(earlyState.LastUnlockAt == observed, "actual unlock timestamp retained");
    if (sample.Expected is not null)
    {
        var arrival = earlyState.Arrivals["2026-10-23"];
        Check(Attendance.Departure(arrival, earlyState.Settings) == sample.Expected.Value.AddHours(9), "normalized start drives departure");
        Check(!Attendance.RecordUnlock(earlyState, At(2026, 10, 23, 9, 30)) &&
              Attendance.Today(earlyState, observed)?.Time == sample.Expected, "later unlock preserves normalized first arrival");
    }
}
foreach (var mode in Enum.GetValues<WorkdayMode>())
{
    var manualState = new AttendanceState();
    bool earlyRejected = false;
    try { Attendance.SetManual(manualState, At(2026, 10, 23, 7, 0), At(2026, 10, 23, 9, 0), mode); }
    catch (ArgumentException) { earlyRejected = true; }
    Check(earlyRejected && manualState.Arrivals.Count == 0, "manual early input remains invalid: " + mode);
}
var protectedState = new AttendanceState();
Attendance.SetManual(protectedState, At(2026, 10, 23, 8, 30), At(2026, 10, 23, 9, 0), WorkdayMode.AfternoonHalf);
Check(!Attendance.RecordUnlock(protectedState, At(2026, 10, 23, 6, 0)) &&
      protectedState.Arrivals["2026-10-23"].Time == At(2026, 10, 23, 8, 30) &&
      protectedState.Arrivals["2026-10-23"].Mode == WorkdayMode.AfternoonHalf, "manual half-day record protected from early event");
Attendance.SkipToday(protectedState, At(2026, 10, 23, 6, 0));
Check(!Attendance.RecordUnlock(protectedState, At(2026, 10, 23, 6, 0)) && protectedState.Arrivals.Count == 0,
      "day off suppresses early arrival");
var state = new AttendanceState();
var first = At(2026, 10, 2, 8, 30);
Check(Attendance.RecordUnlock(state, first), "first observed unlock records arrival");
Check(!Attendance.RecordUnlock(state, At(2026, 10, 2, 9, 0)), "second unlock does not overwrite first");
Check(Attendance.Today(state, first)?.Time == first, "first arrival retained");
Check(state.LastUnlockAt == At(2026, 10, 2, 9, 0), "last actual unlock retained");
Check(Attendance.Departure(state.Arrivals[Attendance.DayKey(first)], state.Settings) ==
      At(2026, 10, 2, 17, 30), "ordinary day includes work and break");
Check(Attendance.RecordUnlock(state, At(2026, 10, 30, 8, 30)) &&
      Attendance.Departure(state.Arrivals["2026-10-30"], state.Settings) == At(2026, 10, 30, 15, 30),
      "last Friday shortens normal day by two hours");
Check(Attendance.RemainingMinutes(At(2026, 10, 2, 15, 30), At(2026, 10, 2, 15, 29)) == 1,
      "remaining minute rounds up");
Check(!Attendance.RecordUnlock(state, At(2026, 10, 3, 5, 59)), "early unlock is not an arrival");
Check(Attendance.RecordUnlock(state, At(2026, 10, 3, 13, 30)), "afternoon unlock infers morning half day");
Check(Attendance.Today(state, At(2026, 10, 3, 14, 0))?.Mode == WorkdayMode.MorningHalf,
      "morning half day mode persisted");
Check(Attendance.Departure(state.Arrivals["2026-10-03"], state.Settings) == At(2026, 10, 3, 17, 30),
      "half day ends four hours after arrival without break");
Attendance.SkipToday(state, At(2026, 10, 3, 14, 0));
Check(!Attendance.RecordUnlock(state, At(2026, 10, 3, 14, 15)), "day off suppresses later unlocks");
Attendance.SetManual(state, At(2026, 10, 3, 13, 15), At(2026, 10, 3, 14, 20), WorkdayMode.MorningHalf);
Check(!state.SuppressedDays.Contains("2026-10-03"), "manual entry resumes after day off");
Attendance.SetManual(state, At(2026, 10, 4, 9, 0), At(2026, 10, 4, 9, 30), WorkdayMode.AfternoonHalf);
Check(Attendance.Today(state, At(2026, 10, 4, 9, 30))?.Mode == WorkdayMode.AfternoonHalf,
      "afternoon half day can be selected manually");
bool rejected = false;
try { Attendance.SetManual(state, At(2026, 10, 4, 11, 0), At(2026, 10, 4, 12, 0), null); }
catch (ArgumentException) { rejected = true; }
Check(rejected, "out-of-window manual arrival rejected");
rejected = false;
try { Attendance.SetManual(state, At(2026, 10, 4, 9, 45), At(2026, 10, 4, 9, 30), null); }
catch (ArgumentException) { rejected = true; }
Check(rejected, "future manual arrival rejected");
Check(Attendance.IsLastFriday(At(2026, 10, 30, 9, 0)), "last Friday identified");
Check(!Attendance.IsLastFriday(At(2026, 10, 23, 9, 0)), "ordinary Friday identified");

var overtimeState = new AttendanceState();
Check(Attendance.Overtime(overtimeState, At(2026, 10, 6, 18, 31)) is null,
      "no overtime guide without an arrival");
Attendance.SetManual(overtimeState, At(2026, 10, 6, 9, 0),
                     At(2026, 10, 6, 9, 30), WorkdayMode.Normal);
DateTimeOffset planned = Attendance.Departure(overtimeState.Arrivals["2026-10-06"], overtimeState.Settings);
Check(Attendance.MealThresholdAt(overtimeState.Arrivals["2026-10-06"], overtimeState.Settings) ==
      At(2026, 10, 6, 20, 0), "meal threshold clock follows planned departure by two hours");
Check(Attendance.Overtime(overtimeState, planned.AddMinutes(-1)) is null,
      "no overtime guide before departure");
Check(Attendance.Overtime(overtimeState, planned) == new OvertimeStatus(0, 120),
      "meal countdown starts at planned departure");
Check(Attendance.Overtime(overtimeState, planned.AddMinutes(30).AddSeconds(-1)) == new OvertimeStatus(29, 91),
      "before thirty minutes meal guide remains but extra display threshold is unmet");
Check(Attendance.Overtime(overtimeState, planned.AddMinutes(30)) == new OvertimeStatus(30, 90),
      "thirty-minute boundary uses floor elapsed and ceil meal countdown");
Check(Attendance.Overtime(overtimeState, planned.AddMinutes(31).AddSeconds(59)) == new OvertimeStatus(31, 89),
      "elapsed minutes floor while meal countdown rounds up");
Check(Attendance.Overtime(overtimeState, planned.AddMinutes(119).AddSeconds(1)) == new OvertimeStatus(119, 1),
      "meal countdown remains one until exact threshold");
Check(Attendance.Overtime(overtimeState, planned.AddMinutes(120)) is { MealThresholdReached: true, MinutesToMealThreshold: 0 },
      "meal time threshold reached at two hours");
Attendance.SkipToday(overtimeState, At(2026, 10, 6, 19, 0));
Check(Attendance.Overtime(overtimeState, planned.AddMinutes(121)) is null,
      "day off removes overtime guide");
var fridayStatus = Attendance.Overtime(state, At(2026, 10, 30, 16, 1));
Check(fridayStatus == new OvertimeStatus(31, 89), "last Friday overtime uses shortened departure");
var halfStatus = Attendance.Overtime(state, At(2026, 10, 4, 13, 31));
Check(halfStatus == new OvertimeStatus(31, 89), "half-day overtime uses four-hour departure");

var displayNow = At(2026, 10, 6, 9, 0);
var displayLeave = displayNow.AddHours(1).AddMinutes(1).AddMilliseconds(1);
Check(new AttendanceState().RemainingTimeUnit == RemainingTimeUnit.HoursMinutes, "default display remains hours/minutes");
Check(RemainingTimeDisplay.Format(displayLeave, displayNow, RemainingTimeUnit.HoursMinutes, true) == "1시간 2분", "default minutes round up across fractional boundary");
Check(RemainingTimeDisplay.Format(displayLeave, displayNow, RemainingTimeUnit.Hours, false) == "1.1 h", "hours round up to one tenth");
Check(RemainingTimeDisplay.Format(displayNow.AddMinutes(90), displayNow, RemainingTimeUnit.Hours, true) == "1.5시간", "ninety minutes displays one and a half hours");
Check(RemainingTimeDisplay.Format(displayNow.AddMinutes(30), displayNow, RemainingTimeUnit.Hours, true) == "0.5시간", "thirty minutes displays half an hour");
Check(RemainingTimeDisplay.Format(displayNow.AddHours(1), displayNow, RemainingTimeUnit.Hours, false) == "1 h", "whole hour omits trailing decimal");
Check(RemainingTimeDisplay.Format(displayNow.AddHours(1).AddTicks(-1), displayNow, RemainingTimeUnit.Hours, false) == "1 h", "just below a whole hour remains one hour");
Check(RemainingTimeDisplay.Format(displayNow.AddHours(1).AddTicks(1), displayNow, RemainingTimeUnit.Hours, false) == "1.1 h", "just above a whole hour rounds up");
Check(RemainingTimeDisplay.Format(displayNow.AddMinutes(6), displayNow, RemainingTimeUnit.Hours, false) == "0.1 h", "exact tenth-hour boundary");
Check(RemainingTimeDisplay.Format(displayNow.AddMinutes(6).AddTicks(1), displayNow, RemainingTimeUnit.Hours, false) == "0.2 h", "just above a tenth-hour boundary rounds up");
Check(RemainingTimeDisplay.Format(displayNow, displayNow, RemainingTimeUnit.Hours, false) == "0 h" &&
      RemainingTimeDisplay.Format(displayNow.AddTicks(-1), displayNow, RemainingTimeUnit.Hours, true) == "0시간",
      "zero and expired hours display zero");
var originalCulture = CultureInfo.CurrentCulture;
try
{
    CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("fr-FR");
    Check(RemainingTimeDisplay.Format(displayNow.AddMinutes(90), displayNow, RemainingTimeUnit.Hours, false) == "1.5 h" &&
          RemainingTimeDisplay.Format(displayNow.AddMinutes(30), displayNow, RemainingTimeUnit.Hours, true) == "0.5시간",
          "hour decimal separator stays invariant in English and Korean under French culture");
}
finally
{
    CultureInfo.CurrentCulture = originalCulture;
}
Check(RemainingTimeDisplay.Format(displayLeave, displayNow, RemainingTimeUnit.Minutes, false) == "62 min", "minutes round up");
Check(RemainingTimeDisplay.Format(displayLeave, displayNow, RemainingTimeUnit.Seconds, true) == "3661초", "seconds round up");
Check(RemainingTimeDisplay.Format(displayNow.AddMilliseconds(100), displayNow, RemainingTimeUnit.Milliseconds, false) == "100 ms", "milliseconds use actual remaining duration");
foreach (var unit in Enum.GetValues<RemainingTimeUnit>())
{
    Check(RemainingTimeDisplay.Format(displayNow, displayNow.AddHours(1), unit, false).StartsWith("0"), "elapsed countdown clamps to zero: " + unit);
    Check(RemainingTimeDisplay.Format(displayNow.AddTicks(1), displayNow, unit, false).StartsWith(unit switch { RemainingTimeUnit.HoursMinutes => "0h 1m", RemainingTimeUnit.Hours => "0.1", _ => "1" }), "positive fraction never appears expired: " + unit);
}
Check(RemainingTimeDisplay.RefreshInterval(RemainingTimeUnit.Milliseconds, true) == 100 &&
      RemainingTimeDisplay.RefreshInterval(RemainingTimeUnit.Milliseconds, false) == 1000 &&
      RemainingTimeDisplay.RefreshInterval(RemainingTimeUnit.Seconds, true) == 1000,
      "fast timer only while millisecond countdown active");

string root = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "happylulu-checks-" + Guid.NewGuid().ToString("N"));
try
{
    var store = new StateStore(System.IO.Path.Combine(root, "state.json"));
    state.Language = UiLanguage.Korean;
    state.RemainingTimeUnit = RemainingTimeUnit.Hours;
    store.Save(state);
    var loaded = store.Load();
    Check(loaded.Arrivals.Count == state.Arrivals.Count && loaded.SuppressedDays.SetEquals(state.SuppressedDays),
          "local state round trip");
    Check(loaded.Language == UiLanguage.Korean, "language preference round trip");
    Check(loaded.RemainingTimeUnit == RemainingTimeUnit.Hours && loaded.Copy().RemainingTimeUnit == RemainingTimeUnit.Hours,
          "remaining unit persists and survives copy");
    string original = File.ReadAllText(store.Path);
    var legacy = System.Text.Json.Nodes.JsonNode.Parse(original)!;
    legacy.AsObject().Remove("RemainingTimeUnit");
    File.WriteAllText(store.Path, legacy.ToJsonString());
    Check(store.Load().RemainingTimeUnit == RemainingTimeUnit.HoursMinutes, "legacy state defaults without migration");
    File.WriteAllText(store.Path, original);
    var invalidUnit = loaded.Copy();
    invalidUnit.RemainingTimeUnit = (RemainingTimeUnit)999;
    rejected = false;
    try { store.Save(invalidUnit); }
    catch (InvalidDataException) { rejected = true; }
    Check(rejected && File.ReadAllText(store.Path) == original, "invalid display preference preserves saved file");
    var invalid = loaded.Copy();
    invalid.Settings.WorkMinutes = 0;
    rejected = false;
    try { store.Save(invalid); }
    catch (InvalidDataException) { rejected = true; }
    Check(rejected && File.ReadAllText(store.Path) == original, "invalid state preserves saved file");
    File.WriteAllText(store.Path, "{broken");
    rejected = false;
    try { store.Load(); }
    catch (System.Text.Json.JsonException) { rejected = true; }
    Check(rejected && File.ReadAllText(store.Path) == "{broken", "corrupt state is not rewritten");
}
finally
{
    if (Directory.Exists(root)) Directory.Delete(root, true);
}

Console.WriteLine($"HappyLulu Windows core: {checks} checks passed.");
