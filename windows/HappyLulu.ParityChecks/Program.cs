using System.Globalization;
using System.Text.Json;
using HappyLulu.Core;

void Require(bool condition, string message)
{
    if (!condition) throw new Exception(message);
}

try
{
    Require(args.Length == 1, "Pass the shared attendance JSON path");
    using var document = JsonDocument.Parse(File.ReadAllText(args[0]));
    var fixture = document.RootElement;
    Require(fixture.GetProperty("schema").GetInt32() == 1, "Unsupported fixture schema");
    var zone = TimeZoneInfo.FindSystemTimeZoneById(fixture.GetProperty("timeZone").GetString()!);
    var cases = fixture.GetProperty("cases");
    Require(cases.GetArrayLength() > 0, "Fixture must contain cases");
    var ids = new HashSet<string>(StringComparer.Ordinal);
    foreach (var sample in cases.EnumerateArray())
    {
        string? id = sample.GetProperty("id").GetString();
        Require(!string.IsNullOrWhiteSpace(id) && ids.Add(id), $"Empty or duplicate case id: {id}");
        var parsed = DateTimeOffset.ParseExact(sample.GetProperty("at").GetString()!,
                                              new[] { "yyyy-MM-dd'T'HH:mm:sszzz", "yyyy-MM-dd'T'HH:mm:ss'Z'" },
                                              CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal);
        var at = TimeZoneInfo.ConvertTime(parsed, zone);
        var mode = sample.GetProperty("mode").GetString() switch
        {
            "normal" => WorkdayMode.Normal,
            "morningHalf" => WorkdayMode.MorningHalf,
            "afternoonHalf" => WorkdayMode.AfternoonHalf,
            _ => throw new Exception($"{id}: invalid workday mode")
        };
        var settings = new WorkSettings
        {
            WorkMinutes = sample.GetProperty("workMinutes").GetInt32(),
            BreakMinutes = sample.GetProperty("breakMinutes").GetInt32()
        };
        Require(settings.IsValid, $"{id}: invalid work settings");
        var arrival = new Arrival { Day = Attendance.DayKey(at), Time = at, Source = ArrivalSource.Manual, Mode = mode };
        double minutes = (Attendance.Departure(arrival, settings) - at).TotalMinutes;
        bool allowed = Attendance.IsAllowed(at, mode);
        var expected = sample.GetProperty("expected");
        int expectedMinutes = expected.GetProperty("departureMinutes").GetInt32();
        bool expectedAllowed = expected.GetProperty("arrivalAllowed").GetBoolean();
        Require(minutes == expectedMinutes, $"{id}: departure minutes expected {expectedMinutes}, got {minutes}");
        Require(allowed == expectedAllowed, $"{id}: arrival eligibility expected {expectedAllowed}, got {allowed}");
        if (expected.TryGetProperty("automaticRecordedAt", out var automatic))
        {
            var state = new AttendanceState();
            string recordedAt = automatic.GetString()!;
            Require(Attendance.RecordUnlock(state, at) == (recordedAt.Length > 0), $"{id}: automatic eligibility differs");
            if (recordedAt.Length > 0)
            {
                var normalized = DateTimeOffset.Parse(recordedAt, CultureInfo.InvariantCulture);
                Require(Attendance.Today(state, at)?.Time == normalized, $"{id}: automatic recorded time differs");
            }
        }
    }
    Console.WriteLine($"PASS C# shared attendance: {ids.Count} cases");
    return 0;
}
catch (Exception error)
{
    Console.Error.WriteLine($"FAIL C# shared attendance: {error.Message}");
    return 1;
}
