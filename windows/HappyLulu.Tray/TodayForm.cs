using System.Drawing;
using System.Globalization;
using HappyLulu.Core;

namespace HappyLulu.Tray;

internal sealed class TodayForm : Form
{
    private readonly AppController controller;
    private readonly Panel viewport = new() { Dock = DockStyle.Fill, AutoScroll = true, BackColor = UiPalette.Page };
    private readonly FlowLayoutPanel stack = new()
    {
        Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
        FlowDirection = FlowDirection.TopDown, WrapContents = false,
        Padding = new Padding(22), BackColor = UiPalette.Page
    };
    private readonly Panel header = new() { Height = 80, BackColor = UiPalette.Page };
    private readonly RoundedCard hero = new(UiPalette.MintWash) { Height = 192 };
    private readonly TableLayoutPanel timeCards = new() { Height = 130, ColumnCount = 2, RowCount = 1, BackColor = UiPalette.Page };
    private readonly RoundedCard arrivalCard = new(UiPalette.Card);
    private readonly RoundedCard departureCard = new(UiPalette.Card);
    private readonly RoundedCard overtimeCard = new(UiPalette.MintWash) { Height = 166, Visible = false };
    private readonly TableLayoutPanel actions = new() { Height = 48, ColumnCount = 2, RowCount = 1, BackColor = UiPalette.Page };
    private readonly Label dateLabel = Label(9, false, UiPalette.Muted, UiPalette.Page, 31);
    private readonly Label eyebrow = Label(9, true, UiPalette.Mint, UiPalette.MintWash, 24);
    private readonly Label heading = Label(28, true, UiPalette.Ink, UiPalette.MintWash, 61);
    private readonly Label subheading = Label(10, false, UiPalette.Muted, UiPalette.MintWash, 38);
    private readonly MintProgressTrack progress = new();
    private readonly Label arrivalTitle = Label(9, false, UiPalette.Muted, UiPalette.Card, 22);
    private readonly Label arrivalTime = Label(23, true, UiPalette.Ink, UiPalette.Card, 44);
    private readonly Label arrivalNote = Label(9, false, UiPalette.Muted, UiPalette.Card, 33);
    private readonly Label departureTitle = Label(9, false, UiPalette.Muted, UiPalette.Card, 22);
    private readonly Label departureTime = Label(23, true, UiPalette.Ink, UiPalette.Card, 44);
    private readonly Label departureNote = Label(9, false, UiPalette.Muted, UiPalette.Card, 33);
    private readonly Label overtimeTitle = Label(18, true, UiPalette.Ink, UiPalette.MintWash, 36);
    private readonly Label mealStatus = Label(11, true, UiPalette.MintDeep, UiPalette.MintWash, 42);
    private readonly Label overtimeNote = Label(9, false, UiPalette.Muted, UiPalette.MintWash, 52);
    private readonly Label lastUnlock = Label(9, false, UiPalette.Muted, UiPalette.Page, 36);
    private readonly Label errorLabel = Label(9, false, UiPalette.Warning, UiPalette.Page, 42);
    private readonly Button manualButton = new();
    private readonly Button dayOffButton = new();
    private readonly Button settingsButton = new();

    public TodayForm(AppController controller, Action showSettings, Icon appIcon)
    {
        this.controller = controller;
        Text = "HappyLulu";
        Icon = appIcon;
        Font = new Font("Segoe UI", 10);
        BackColor = UiPalette.Page;
        AutoScaleMode = AutoScaleMode.Dpi;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(450, 625);
        MinimumSize = new Size(420, 500);
        Controls.Add(viewport);
        viewport.Controls.Add(stack);

        BuildHeader(appIcon);
        BuildHero();
        BuildTimeCards();
        BuildOvertimeCard();
        BuildActions(showSettings);
        AddRow(header, 14);
        AddRow(hero, 13);
        AddRow(timeCards, 13);
        AddRow(overtimeCard, 13);
        AddRow(lastUnlock, 5);
        errorLabel.Visible = false;
        AddRow(errorLabel, 5);
        AddRow(actions, 8);
        AddRow(settingsButton, 0);
        viewport.Resize += (_, _) => LayoutWidths();
        Shown += (_, _) => LayoutWidths();
        LayoutWidths();
        FormClosing += (_, args) =>
        {
            if (args.CloseReason == CloseReason.UserClosing)
            {
                args.Cancel = true;
                Hide();
            }
        };
        RefreshView();
    }

    private static Label Label(float size, bool bold, Color color, Color background, int height) => new()
    {
        AutoSize = false, Height = height, BackColor = background, ForeColor = color,
        Font = new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular),
        TextAlign = ContentAlignment.MiddleLeft
    };

    private void AddRow(Control control, int gap)
    {
        control.Margin = new Padding(0, 0, 0, gap);
        stack.Controls.Add(control);
    }

    private void BuildHeader(Icon appIcon)
    {
        var brand = new PictureBox
        {
            Image = appIcon.ToBitmap(), SizeMode = PictureBoxSizeMode.Zoom,
            Location = new Point(0, 4), Size = new Size(44, 44),
            AccessibleName = "HappyLulu"
        };
        var title = Label(16, true, UiPalette.Ink, UiPalette.Page, 29);
        title.Text = "HappyLulu";
        title.SetBounds(56, 2, 230, 29);
        var tagline = Label(9, false, UiPalette.Muted, UiPalette.Page, 22);
        tagline.Text = Words.T("우리의 하루를 더 즐겁게.", "Make every day brighter.");
        tagline.SetBounds(56, 29, 270, 22);
        dateLabel.TextAlign = ContentAlignment.MiddleRight;
        dateLabel.SetBounds(0, 53, 125, 24);
        header.Controls.AddRange(new Control[] { brand, title, tagline, dateLabel });
    }

    private void BuildHero()
    {
        eyebrow.SetBounds(20, 17, 330, 24);
        heading.SetBounds(20, 45, 330, 61);
        subheading.SetBounds(20, 111, 330, 38);
        progress.SetBounds(20, 165, 330, 9);
        progress.AccessibleName = Words.T("오늘의 근무 진행률", "Today's work progress");
        hero.Controls.AddRange(new Control[] { eyebrow, heading, subheading, progress });
        hero.Resize += (_, _) =>
        {
            int width = Math.Max(150, hero.ClientSize.Width - 40);
            eyebrow.Width = heading.Width = subheading.Width = progress.Width = width;
        };
    }

    private void BuildTimeCards()
    {
        timeCards.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        timeCards.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        arrivalCard.Dock = departureCard.Dock = DockStyle.Fill;
        arrivalCard.Margin = new Padding(0, 0, 6, 0);
        departureCard.Margin = new Padding(6, 0, 0, 0);
        FillTimeCard(arrivalCard, arrivalTitle, arrivalTime, arrivalNote);
        FillTimeCard(departureCard, departureTitle, departureTime, departureNote);
        timeCards.Controls.Add(arrivalCard, 0, 0);
        timeCards.Controls.Add(departureCard, 1, 0);
    }

    private static void FillTimeCard(RoundedCard card, Label title, Label time, Label note)
    {
        title.SetBounds(15, 14, 140, 22);
        time.SetBounds(15, 36, 140, 44);
        note.SetBounds(15, 82, 140, 33);
        card.Controls.AddRange(new Control[] { title, time, note });
        card.Resize += (_, _) => title.Width = time.Width = note.Width = Math.Max(80, card.ClientSize.Width - 30);
    }

    private void BuildOvertimeCard()
    {
        overtimeTitle.SetBounds(20, 14, 330, 36);
        mealStatus.SetBounds(20, 52, 330, 42);
        overtimeNote.SetBounds(20, 101, 330, 52);
        overtimeCard.Controls.AddRange(new Control[] { overtimeTitle, mealStatus, overtimeNote });
        overtimeCard.Resize += (_, _) =>
        {
            int width = Math.Max(150, overtimeCard.ClientSize.Width - 40);
            overtimeTitle.Width = mealStatus.Width = overtimeNote.Width = width;
        };
    }

    private void BuildActions(Action showSettings)
    {
        actions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 60));
        actions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 40));
        manualButton.Text = Words.T("출근 시각 입력·수정", "Enter/edit arrival");
        manualButton.AccessibleName = manualButton.Text;
        manualButton.Dock = DockStyle.Fill;
        manualButton.BackColor = UiPalette.Mint;
        manualButton.ForeColor = Color.White;
        manualButton.FlatStyle = FlatStyle.Flat;
        manualButton.FlatAppearance.BorderSize = 0;
        manualButton.FlatAppearance.MouseOverBackColor = UiPalette.MintDeep;
        manualButton.Margin = new Padding(0, 0, 6, 0);
        manualButton.Click += (_, _) => ShowManualDialog();
        dayOffButton.Text = Words.T("오늘 쉬는 날", "Day off today");
        dayOffButton.AccessibleName = dayOffButton.Text;
        dayOffButton.Dock = DockStyle.Fill;
        dayOffButton.BackColor = UiPalette.Card;
        dayOffButton.ForeColor = UiPalette.MintDeep;
        dayOffButton.FlatStyle = FlatStyle.Flat;
        dayOffButton.FlatAppearance.BorderColor = UiPalette.Border;
        dayOffButton.Margin = new Padding(6, 0, 0, 0);
        dayOffButton.Click += (_, _) => SkipToday();
        actions.Controls.Add(manualButton, 0, 0);
        actions.Controls.Add(dayOffButton, 1, 0);

        settingsButton.Text = Words.T("설정 열기  ›", "Open settings  ›");
        settingsButton.AccessibleName = Words.T("설정 열기", "Open settings");
        settingsButton.Height = 32;
        settingsButton.TextAlign = ContentAlignment.MiddleLeft;
        settingsButton.FlatStyle = FlatStyle.Flat;
        settingsButton.FlatAppearance.BorderSize = 0;
        settingsButton.BackColor = UiPalette.Page;
        settingsButton.ForeColor = UiPalette.MintDeep;
        settingsButton.Click += (_, _) => showSettings();
    }

    private void LayoutWidths()
    {
        int width = Math.Max(310, viewport.ClientSize.Width - stack.Padding.Horizontal -
                                   SystemInformation.VerticalScrollBarWidth - 6);
        foreach (Control row in stack.Controls) row.Width = width;
        dateLabel.Left = Math.Max(0, header.Width - dateLabel.Width);
        ResizeMessages();
    }

    private static int WrappedHeight(Label label, int minimum)
    {
        if (string.IsNullOrEmpty(label.Text)) return minimum;
        int measured = TextRenderer.MeasureText(label.Text, label.Font,
            new Size(Math.Max(120, label.Width), 1000), TextFormatFlags.WordBreak).Height;
        return Math.Max(minimum, measured + 6);
    }

    private void ResizeMessages()
    {
        heading.Height = WrappedHeight(heading, 61);
        subheading.Top = heading.Bottom + 5;
        progress.Top = subheading.Bottom + 16;
        hero.Height = progress.Bottom + 18;
        if (overtimeCard.Visible)
        {
            mealStatus.Height = WrappedHeight(mealStatus, 42);
            overtimeNote.Top = mealStatus.Bottom + 6;
            overtimeNote.Height = WrappedHeight(overtimeNote, 52);
            overtimeCard.Height = overtimeNote.Bottom + 12;
        }
        if (errorLabel.Visible) errorLabel.Height = WrappedHeight(errorLabel, 42);
    }

    public void RefreshView(DateTimeOffset? snapshot = null)
    {
        DateTimeOffset now = snapshot ?? DateTimeOffset.Now;
        Arrival? arrival = Attendance.Today(controller.State, now);
        bool skipped = controller.State.SuppressedDays.Contains(Attendance.DayKey(now));
        dateLabel.Text = Words.Korean
            ? now.ToString("M월 d일 dddd", CultureInfo.GetCultureInfo("ko-KR"))
            : now.ToString("ddd, MMM d", CultureInfo.GetCultureInfo("en-US"));
        arrivalTitle.Text = Words.T("출근", "ARRIVAL");
        departureTitle.Text = Words.T("퇴근 예정", "EXPECTED LEAVE");
        if (arrival is null)
        {
            eyebrow.Text = Words.T("오늘", "TODAY");
            heading.Text = skipped ? Words.T("오늘은 쉬어가요", "Taking today off")
                                   : Words.T("출근 기록 대기", "Waiting for arrival");
            subheading.Text = skipped ? Words.T("오늘 자동 기록을 쉬고 있어요.", "Automatic recording is paused today.")
                                      : Words.T("실제 세션 잠금 해제를 기다려요.", "Waiting for an actual session unlock.");
            arrivalTime.Text = departureTime.Text = "—";
            arrivalNote.Text = Words.T("아직 기록 없음", "No record yet");
            departureNote.Text = Words.T("출근 후 계산", "Calculated after arrival");
            progress.Fraction = 0;
        }
        else
        {
            DateTimeOffset leave = Attendance.Departure(arrival, controller.State.Settings);
            int left = Attendance.RemainingMinutes(leave, now);
            eyebrow.Text = Words.T("퇴근까지", "TIME TO GO HOME");
            heading.Text = left == 0 ? Words.T("오늘도 수고했어요", "Great work today") : RemainingTimeDisplay.Format(leave, now, controller.State.RemainingTimeUnit, Words.Korean);
            subheading.Text = left == 0 ? Words.T("예정 퇴근 시각이 지났어요.", "The planned departure time has passed.")
                                        : Words.T("퇴근까지 남았어요", "Time until planned departure");
            arrivalTime.Text = arrival.Time.ToString("HH:mm", CultureInfo.InvariantCulture);
            departureTime.Text = leave.ToString("HH:mm", CultureInfo.InvariantCulture);
            arrivalNote.Text = Words.Mode(arrival.Mode) + " · " +
                (arrival.Source == ArrivalSource.Unlock ? Words.T("잠금 해제", "Unlock") : Words.T("직접 입력", "Manual"));
            departureNote.Text = arrival.Mode != WorkdayMode.Normal
                ? Words.T("반차 · 휴게 없이 4시간", "Half-day · 4 hours")
                : Attendance.IsLastFriday(arrival.Time)
                    ? Words.T("마지막 금요일 · 2시간 단축", "Last Friday · 2 hours early")
                    : Words.T("휴게시간 포함", "Includes break");
            progress.Fraction = Attendance.Progress(arrival, leave, now);
        }

        OvertimeStatus? overtime = Attendance.Overtime(controller.State, now);
        overtimeCard.Visible = overtime is not null;
        if (overtime is { } status)
        {
            DateTimeOffset mealAt = Attendance.MealThresholdAt(arrival!, controller.State.Settings);
            string mealClock = mealAt.ToString("HH:mm", CultureInfo.InvariantCulture);
            overtimeTitle.Text = status.ElapsedMinutes >= Attendance.ExtraTimeDisplayDelayMinutes
                ? Words.T($"추가 {status.ElapsedMinutes}분 중", $"Extra {status.ElapsedMinutes} min in progress")
                : Words.T("예정 퇴근 시각 지남", "Planned departure passed");
            mealStatus.Text = status.MealThresholdReached
                ? Words.T($"식대 기준 {mealClock} · 시각 도달", $"Meal time threshold {mealClock} · reached")
                : Words.T($"식대 기준 {mealClock} · {status.MinutesToMealThreshold}분 남음",
                          $"Meal time threshold {mealClock} · {status.MinutesToMealThreshold} min left");
            overtimeNote.Text = Words.T("예정 시각 기준 안내입니다. 실제 근무·식대 지급 승인 여부는 확인하지 않아요.",
                                        "Timing guide only; actual work and meal reimbursement approval are not verified.");
        }

        lastUnlock.Text = controller.State.LastUnlockAt is { } seen
            ? Words.T($"최근 잠금 해제 감지 · {seen:MM-dd HH:mm}", $"Last unlock detected · {seen:MMM d, HH:mm}")
            : Words.T("잠금 해제 감지 대기 중 · 일반 08–10시, 오전 반차 13–15시",
                      "Waiting for unlock · full day 08–10, morning off 13–15");
        errorLabel.Text = controller.Error ?? "";
        errorLabel.Visible = !string.IsNullOrEmpty(errorLabel.Text);
        ResizeMessages();
        dayOffButton.Enabled = !skipped;
    }

    private void SkipToday()
    {
        var answer = MessageBox.Show(this,
            Words.T("오늘 기록을 지우고 다음 잠금 해제도 기록하지 않을까요?", "Clear today's arrival and skip later unlocks today?"),
            Words.T("오늘 쉬는 날", "Day off today"), MessageBoxButtons.YesNo, MessageBoxIcon.Question);
        if (answer == DialogResult.Yes && !controller.SkipToday()) ShowError();
    }

    private void ShowManualDialog()
    {
        using var dialog = new Form
        {
            Text = Words.T("출근 시각", "Arrival time"), StartPosition = FormStartPosition.CenterParent,
            ClientSize = new Size(360, 240), FormBorderStyle = FormBorderStyle.FixedDialog,
            MaximizeBox = false, MinimizeBox = false, Font = Font, BackColor = UiPalette.Page,
            AutoScaleMode = AutoScaleMode.Dpi
        };
        Arrival? existingArrival = Attendance.Today(controller.State, DateTimeOffset.Now);
        var timeTitle = Label(9, true, UiPalette.Muted, UiPalette.Page, 24);
        timeTitle.Text = Words.T("오늘 출근", "Arrival today");
        timeTitle.SetBounds(20, 16, 310, 24);
        var time = new DateTimePicker
        {
            Format = DateTimePickerFormat.Time, ShowUpDown = true,
            Value = existingArrival?.Time.LocalDateTime ?? DateTime.Now,
            Left = 20, Top = 43, Width = 320
        };
        var modeTitle = Label(9, true, UiPalette.Muted, UiPalette.Page, 24);
        modeTitle.Text = Words.T("근무 유형", "Workday mode");
        modeTitle.SetBounds(20, 88, 310, 24);
        var mode = new ComboBox { Left = 20, Top = 115, Width = 320, DropDownStyle = ComboBoxStyle.DropDownList };
        mode.Items.AddRange(new object[]
        {
            new ModeChoice(null, Words.T("출근 시각으로 자동 판단", "Infer from arrival time")),
            new ModeChoice(WorkdayMode.Normal, Words.Mode(WorkdayMode.Normal)),
            new ModeChoice(WorkdayMode.MorningHalf, Words.Mode(WorkdayMode.MorningHalf)),
            new ModeChoice(WorkdayMode.AfternoonHalf, Words.Mode(WorkdayMode.AfternoonHalf))
        });
        mode.SelectedIndex = existingArrival?.Mode switch
        {
            WorkdayMode.Normal => 1,
            WorkdayMode.MorningHalf => 2,
            WorkdayMode.AfternoonHalf => 3,
            _ => 0
        };
        var cancel = new Button { Text = Words.T("취소", "Cancel"), Left = 164, Top = 180, Width = 82,
                                  DialogResult = DialogResult.Cancel };
        var save = new Button { Text = Words.T("저장", "Save"), Left = 254, Top = 180, Width = 86,
                                BackColor = UiPalette.Mint, ForeColor = Color.White, FlatStyle = FlatStyle.Flat };
        save.FlatAppearance.BorderSize = 0;
        save.Click += (_, _) =>
        {
            DateTime local = DateTime.Today.Add(time.Value.TimeOfDay);
            var at = new DateTimeOffset(local, TimeZoneInfo.Local.GetUtcOffset(local));
            if (controller.ManualArrival(at, ((ModeChoice)mode.SelectedItem!).Mode)) dialog.Close();
            else ShowError();
        };
        dialog.Controls.AddRange(new Control[] { timeTitle, time, modeTitle, mode, cancel, save });
        dialog.CancelButton = cancel;
        dialog.AcceptButton = save;
        dialog.ShowDialog(this);
    }

    private void ShowError() => MessageBox.Show(this, controller.Error ?? Words.T("저장할 수 없어요.", "Could not save."),
        "HappyLulu", MessageBoxButtons.OK, MessageBoxIcon.Warning);

    private sealed record ModeChoice(WorkdayMode? Mode, string Label)
    {
        public override string ToString() => Label;
    }
}
