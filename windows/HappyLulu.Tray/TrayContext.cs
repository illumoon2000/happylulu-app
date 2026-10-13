using System.Collections.Concurrent;
using System.Drawing;
using HappyLulu.Core;
using Microsoft.Win32;

namespace HappyLulu.Tray;

internal sealed class TrayContext : ApplicationContext
{
    private readonly AppController controller = new();
    private readonly ConcurrentQueue<DateTimeOffset> unlockEvents = new();
    private readonly ToolStripMenuItem todayMenu = new();
    private readonly ToolStripMenuItem settingsMenu = new();
    private readonly ToolStripMenuItem exitMenu = new();
    private readonly Icon appIcon = AppIcon.Load();
    private readonly NotifyIcon tray;
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 1000 };
    private TodayForm? today;
    private SettingsForm? settings;
    private UiLanguage displayedLanguage;

    public TrayContext()
    {
        displayedLanguage = controller.State.Language;
        Words.Preference = displayedLanguage;
        var menu = new ContextMenuStrip();
        todayMenu.Click += (_, _) => ShowToday();
        settingsMenu.Click += (_, _) => ShowSettings();
        exitMenu.Click += (_, _) => ExitThread();
        menu.Items.Add(todayMenu);
        menu.Items.Add(settingsMenu);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(exitMenu);
        LocalizeMenu();
        tray = new NotifyIcon
        {
            Icon = appIcon,
            Text = "HappyLulu",
            ContextMenuStrip = menu,
            Visible = true
        };
        tray.MouseClick += (_, args) =>
        {
            if (args.Button == MouseButtons.Left) ShowToday();
        };
        controller.Changed += () =>
        {
            RefreshViews();
            if (settings is { IsDisposed: false, Visible: true }) settings.RefreshView();
        };
        // WinForms supplies the message pump required by SystemEvents.
        SystemEvents.SessionSwitch += OnSessionSwitch;
        timer.Tick += (_, _) =>
        {
            while (unlockEvents.TryDequeue(out DateTimeOffset at)) controller.ObservedUnlock(at);
            if (displayedLanguage != controller.State.Language) ReopenInChosenLanguage();
            RefreshViews();
        };
        timer.Start();
        RefreshViews();
    }

    private void OnSessionSwitch(object? sender, SessionSwitchEventArgs args)
    {
        if (args.Reason == SessionSwitchReason.SessionUnlock)
            unlockEvents.Enqueue(DateTimeOffset.Now);
    }

    private void ShowToday()
    {
        today ??= new TodayForm(controller, ShowSettings, appIcon);
        today.Show();
        today.WindowState = FormWindowState.Normal;
        today.Activate();
        today.RefreshView();
    }

    private void ShowSettings()
    {
        settings ??= new SettingsForm(controller, appIcon);
        settings.Show();
        settings.WindowState = FormWindowState.Normal;
        settings.Activate();
        settings.RefreshView();
    }

    private void RefreshViews()
    {
        DateTimeOffset now = DateTimeOffset.Now;
        Arrival? arrival = Attendance.Today(controller.State, now);
        OvertimeStatus? overtime = Attendance.Overtime(controller.State, now);
        DateTimeOffset? departure = arrival is null ? null : Attendance.Departure(arrival, controller.State.Settings);
        timer.Interval = RemainingTimeDisplay.RefreshInterval(controller.State.RemainingTimeUnit, departure > now);
        string title = overtime is { ElapsedMinutes: >= Attendance.ExtraTimeDisplayDelayMinutes } status
            ? Words.T($"추가 {status.ElapsedMinutes}분 중", $"Extra {status.ElapsedMinutes} min in progress")
            : arrival is null
                ? (controller.State.SuppressedDays.Contains(Attendance.DayKey(now))
                ? Words.T("오늘 쉬는 날", "Day off")
                : Words.T("출근 대기", "Waiting for arrival"))
                : Attendance.RemainingMinutes(Attendance.Departure(arrival, controller.State.Settings), now) == 0
                    ? Words.T("예정 퇴근 시각 지남", "Planned departure passed")
                    : Words.T("퇴근 ", "Leave in ") + RemainingTimeDisplay.Format(departure!.Value, now, controller.State.RemainingTimeUnit, Words.Korean);
        string tooltip = "HappyLulu · " + title;
        string displayedTooltip = tooltip.Length <= 63 ? tooltip : tooltip[..63];
        if (tray.Text != displayedTooltip) tray.Text = displayedTooltip;
        if (today is { IsDisposed: false, Visible: true }) today.RefreshView(now);
    }

    private void LocalizeMenu()
    {
        todayMenu.Text = Words.T("오늘", "Today");
        settingsMenu.Text = Words.T("설정", "Settings");
        exitMenu.Text = Words.T("종료", "Exit");
    }

    private void ReopenInChosenLanguage()
    {
        bool showToday = today is { IsDisposed: false, Visible: true };
        bool showSettings = settings is { IsDisposed: false, Visible: true };
        today?.Dispose();
        settings?.Dispose();
        today = null;
        settings = null;
        displayedLanguage = controller.State.Language;
        Words.Preference = displayedLanguage;
        LocalizeMenu();
        if (showToday) ShowToday();
        if (showSettings) ShowSettings();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            SystemEvents.SessionSwitch -= OnSessionSwitch;
            timer.Stop();
            timer.Dispose();
            tray.Visible = false;
            tray.ContextMenuStrip?.Dispose();
            tray.Dispose();
            today?.Dispose();
            settings?.Dispose();
            appIcon.Dispose();
        }
        base.Dispose(disposing);
    }
}
