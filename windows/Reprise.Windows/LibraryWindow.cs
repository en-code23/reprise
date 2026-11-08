using Reprise.Core;

namespace Reprise.Windows;

internal sealed class LibraryWindow : Form
{
    private readonly SessionStore store;
    private readonly NotifyIcon tray;
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 30_000 };
    private readonly ListBox projects = new() { Dock = DockStyle.Fill, DrawMode = DrawMode.OwnerDrawFixed, ItemHeight = 82, BorderStyle = BorderStyle.None, IntegralHeight = false };
    private readonly DataGridView history = new() { ReadOnly = true, AllowUserToAddRows = false, AllowUserToDeleteRows = false, MultiSelect = false, SelectionMode = DataGridViewSelectionMode.FullRowSelect, RowHeadersVisible = false, AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill, BackgroundColor = Color.White, BorderStyle = BorderStyle.None, Height = 210 };
    private readonly ComboBox model = Theme.Combo(["All assistants", "codex", "claude", "grok", "other"]);
    private readonly ComboBox source = Theme.Combo(["All sources", .. NativeServices.Origins]);
    private readonly ComboBox terminal = Theme.Combo(NativeServices.Terminals);
    private readonly TextBox search = new() { PlaceholderText = "Search projects, sessions, or notes", Dock = DockStyle.Fill };
    private readonly Label title = Theme.Label("Your next session belongs here", 22, true), path = Theme.Label("Add a screenshot, enter a command, or sync local sessions."), message = Theme.Label("Saved on this PC", 9);
    private readonly TextBox command = new() { ReadOnly = true, Multiline = true, WordWrap = true, Height = 65, Font = new Font("Consolas", 10), BorderStyle = BorderStyle.FixedSingle };
    private readonly TextBox note = new() { ReadOnly = true, Multiline = true, ScrollBars = ScrollBars.Vertical, Height = 110, BorderStyle = BorderStyle.FixedSingle };
    private readonly Label origin = Theme.Label("", 9), count = Theme.Label("Projects", 11, true);
    private readonly Button resume, editor, copy, edit, remove, sync, update, chooseEditor;
    private readonly List<Button> areaButtons = [];
    private bool refreshing, syncing, exiting;
    private string area = "Projects";
    private ProjectGroup? CurrentProject => projects.SelectedItem as ProjectGroup;
    private Session? CurrentSession => history.SelectedRows.Count > 0 ? history.SelectedRows[0].Tag as Session : CurrentProject?.Latest;

    internal LibraryWindow(SessionStore store, bool smoke = false)
    {
        this.store = store;
        Text = "Reprise"; Font = new Font("Segoe UI", 10); BackColor = Theme.Paper; ForeColor = Theme.Ink;
        Icon = NativeServices.LoadIcon(); MinimumSize = new Size(1100, 740); Size = new Size(1280, 880); StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        resume = Theme.Button("Resume", (_, _) => Act(() => NativeServices.Resume(CurrentSession!, store.Preferences.Terminal)), true);
        editor = Theme.Button("Open in editor", (_, _) => Act(() => { NativeServices.OpenEditor(CurrentSession!, store.Preferences.EditorPath ?? NativeServices.DefaultEditor()); message.Text = "Project opened. Resume command copied."; }));
        copy = Theme.Button("Copy command", (_, _) => Act(() => { Clipboard.SetText(CurrentSession!.Command); message.Text = "Resume command copied."; }));
        edit = Theme.Button("Edit details", (_, _) => ShowCapture(CurrentSession));
        remove = Theme.Button("Remove session", (_, _) =>
        {
            if (CurrentSession is not { } session) return;
            if (MessageBox.Show(this, "Remove this session from Reprise? Its original CLI conversation stays on disk. You can restore removed imports from Library options.", "Remove session", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
                Act(() => { store.Remove(session); RefreshProjects(); });
        });
        sync = Theme.Button("Sync now", async (_, _) => await Sync());
        update = Theme.Button("Check for updates", async (_, _) => await CheckUpdates());
        chooseEditor = Theme.Button("Choose editor…", (_, _) => EditorMenu().Show(chooseEditor!, new Point(0, chooseEditor!.Height)));
        BuildLayout();
        var trayMenu = new ContextMenuStrip();
        trayMenu.Items.Add("Open library", null, (_, _) => ShowLibrary());
        trayMenu.Items.Add("Add screenshot…", null, (_, _) => ChooseScreenshot());
        trayMenu.Items.Add("Enter a command…", null, (_, _) => ShowCapture());
        trayMenu.Items.Add("Sync local sessions", null, async (_, _) => await Sync());
        trayMenu.Items.Add("Check for updates…", null, async (_, _) => { ShowLibrary(); await CheckUpdates(); });
        trayMenu.Items.Add(new ToolStripSeparator());
        trayMenu.Items.Add("Quit Reprise", null, (_, _) => Quit());
        tray = new NotifyIcon { Text = "Reprise — resume your work", Icon = Icon, Visible = !smoke, ContextMenuStrip = trayMenu };
        tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) ShowLibrary(); };
        timer.Tick += async (_, _) => { if (store.Preferences.AutoDiscovery) await Sync(); };
        if (!smoke) Shown += async (_, _) => { timer.Start(); if (store.Preferences.AutoDiscovery) await Sync(); };
        AllowDrop = true;
        DragEnter += (_, e) => e.Effect = e.Data?.GetDataPresent(DataFormats.FileDrop) == true ? DragDropEffects.Copy : DragDropEffects.None;
        DragDrop += (_, e) => { if (e.Data?.GetData(DataFormats.FileDrop) is string[] { Length: > 0 } files) ShowCapture(image: files[0]); };
        RefreshProjects();
    }

    private void BuildLayout()
    {
        var root = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Margin = new Padding(0), Padding = new Padding(0) };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 210)); root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); Controls.Add(root);
        var sidebar = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 3, ColumnCount = 1, Padding = new Padding(16), Margin = new Padding(0), BackColor = Theme.Paper };
        sidebar.RowStyles.Add(new RowStyle(SizeType.Absolute, 70)); sidebar.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); sidebar.RowStyles.Add(new RowStyle(SizeType.AutoSize)); root.Controls.Add(sidebar, 0, 0);
        var brand = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false, Padding = new Padding(0, 10, 0, 0) };
        brand.Controls.Add(new PictureBox { Image = Icon!.ToBitmap(), SizeMode = PictureBoxSizeMode.Zoom, Size = new Size(34, 34), Margin = new Padding(0, 0, 10, 0) }); brand.Controls.Add(Theme.Label("Reprise", 18, true)); sidebar.Controls.Add(brand, 0, 0);
        var navigation = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Margin = new Padding(0) };
        navigation.Controls.Add(Theme.Label("LIBRARY", 9, true));
        foreach (var item in new[] { "Projects", "Unassigned", "Internal" })
        {
            var button = Theme.Button(item, (_, _) => { area = item; RefreshProjects(); }); button.Width = 170; button.AutoSize = false; button.Tag = item;
            areaButtons.Add(button); navigation.Controls.Add(button);
        }
        navigation.Controls.Add(Theme.Label("ASSISTANT", 9, true)); navigation.Controls.Add(model);
        navigation.Controls.Add(Theme.Label("SOURCE", 9, true)); navigation.Controls.Add(source);
        model.SelectedIndexChanged += (_, _) => RefreshProjects(); source.SelectedIndexChanged += (_, _) => RefreshProjects(); sidebar.Controls.Add(navigation, 0, 1);
        var settings = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Margin = new Padding(0), Padding = new Padding(0, 12, 0, 0) };
        var automatic = new CheckBox { Text = "Auto-save sessions", AutoSize = true, Checked = store.Preferences.AutoDiscovery, Margin = new Padding(0, 0, 0, 12) };
        automatic.CheckedChanged += async (_, _) => { Act(() => { store.Preferences.AutoDiscovery = automatic.Checked; store.SavePreferences(); }); if (automatic.Checked) await Sync(); };
        settings.Controls.Add(automatic); settings.Controls.Add(Theme.Label("DEFAULT TERMINAL", 9, true));
        terminal.SelectedItem = NativeServices.Terminals.Contains(store.Preferences.Terminal) ? store.Preferences.Terminal : "PowerShell";
        terminal.SelectedIndexChanged += (_, _) => Act(() => { store.Preferences.Terminal = terminal.Text; store.SavePreferences(); ShowSession(); }); settings.Controls.Add(terminal);
        settings.Controls.Add(Theme.Label("DEFAULT EDITOR", 9, true)); chooseEditor.Width = 170; chooseEditor.AutoSize = false; settings.Controls.Add(chooseEditor);
        update.Width = 170; update.AutoSize = false; settings.Controls.Add(update);
        sync.Width = 170; sync.AutoSize = false; settings.Controls.Add(sync);
        var options = Theme.Button("Library options…", (_, _) =>
        {
            var menu = new ContextMenuStrip();
            menu.Items.Add("Restore removed sessions", null, async (_, _) => { Act(store.RestoreRemoved); await Sync(); });
            menu.Items.Add("Open data folder", null, (_, _) => NativeServices.OpenUrl(store.DataDirectory));
            menu.Items.Add("Quit Reprise", null, (_, _) => Quit()); menu.Show(Cursor.Position);
        }); options.Width = 170; options.AutoSize = false; settings.Controls.Add(options); sidebar.Controls.Add(settings, 0, 2);
        var main = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 3, ColumnCount = 1, Margin = new Padding(0), BackColor = Color.White };
        main.RowStyles.Add(new RowStyle(SizeType.Absolute, 78)); main.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); main.RowStyles.Add(new RowStyle(SizeType.Absolute, 44)); root.Controls.Add(main, 1, 0);
        var toolbar = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, Padding = new Padding(18), Margin = new Padding(0) };
        toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 170)); toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 150));
        search.Margin = new Padding(0, 6, 14, 0); search.TextChanged += (_, _) => RefreshProjects(); toolbar.Controls.Add(search, 0, 0);
        toolbar.Controls.Add(Theme.Button("Add screenshot…", (_, _) => ChooseScreenshot()), 1, 0); toolbar.Controls.Add(Theme.Button("Add session", (_, _) => ShowCapture()), 2, 0); main.Controls.Add(toolbar, 0, 0);
        var split = new SplitContainer { Size = new Size(950, 650), SplitterDistance = 290, Dock = DockStyle.Fill, FixedPanel = FixedPanel.Panel1, Panel1MinSize = 230, Panel2MinSize = 380, SplitterWidth = 5 };
        main.Controls.Add(split, 0, 1);
        Shown += (_, _) => { split.SplitterDistance = Math.Min(290, split.Width - 400); };
        var listPanel = new Panel { Dock = DockStyle.Fill, Padding = new Padding(12), BackColor = Color.White };
        count.Dock = DockStyle.Top; count.Height = 32; count.AutoSize = false; listPanel.Controls.Add(projects); listPanel.Controls.Add(count); split.Panel1.Controls.Add(listPanel);
        projects.BackColor = Color.White; projects.DrawItem += DrawProject; projects.SelectedIndexChanged += (_, _) => { if (!refreshing) BindProject(); };
        var detail = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Padding = new Padding(22), BackColor = Theme.Paper };
        title.AutoSize = false; title.MaximumSize = Size.Empty; title.MinimumSize = new Size(0, 50); title.Height = 50; title.AutoEllipsis = true;
        path.AutoSize = false; path.MaximumSize = Size.Empty; path.MinimumSize = new Size(0, 44); path.Height = 44; path.AutoEllipsis = true; path.ForeColor = Theme.Secondary;
        detail.Controls.Add(title); detail.Controls.Add(path);
        var actions = new FlowLayoutPanel { AutoSize = true, WrapContents = true, Margin = new Padding(0, 0, 0, 10) };
        actions.Controls.AddRange([resume, editor, copy, edit, remove]); detail.Controls.Add(actions);
        detail.Controls.Add(Theme.Label("Sessions · latest first", 12, true));
        history.ColumnHeadersHeightSizeMode = DataGridViewColumnHeadersHeightSizeMode.AutoSize; history.RowTemplate.Height = 40;
        history.DefaultCellStyle.SelectionBackColor = Theme.Sage; history.DefaultCellStyle.SelectionForeColor = Theme.Ink; history.DefaultCellStyle.Padding = new Padding(5);
        history.Columns.Add("Assistant", "Assistant"); history.Columns.Add("Source", "Source"); history.Columns.Add("Updated", "Saved"); history.Columns.Add("Session", "Session");
        history.SelectionChanged += (_, _) => { if (!refreshing) ShowSession(); };
        detail.Controls.Add(history); detail.Controls.Add(Theme.Label("RESUME COMMAND", 9, true)); detail.Controls.Add(command); detail.Controls.Add(origin);
        detail.Controls.Add(Theme.Label("Project note", 12, true)); detail.Controls.Add(note);
        detail.Controls.Add(Theme.Label("Drop a terminal screenshot anywhere in this window to add it. Closing this window keeps Reprise in the tray.", 9));
        detail.SizeChanged += (_, _) =>
        {
            var width = Math.Max(300, detail.ClientSize.Width - 66);
            foreach (Control control in detail.Controls) { control.Width = width; if (control is Label { AutoSize: true } label) label.MaximumSize = new Size(width, 0); }
        };
        split.Panel2.Controls.Add(detail);
        message.Dock = DockStyle.Fill; message.AutoSize = false; message.Padding = new Padding(18, 9, 12, 0); message.ForeColor = Theme.Secondary; main.Controls.Add(message, 0, 2);
    }
    private void DrawProject(object? sender, DrawItemEventArgs e)
    {
        if (e.Index < 0 || projects.Items[e.Index] is not ProjectGroup group) return;
        var selected = (e.State & DrawItemState.Selected) != 0;
        using var fill = new SolidBrush(selected ? Theme.Sage : Color.White); e.Graphics.FillRectangle(fill, e.Bounds);
        var bounds = Rectangle.Inflate(e.Bounds, -10, -8);
        using var bold = new Font(Font, FontStyle.Bold);
        using var small = new Font("Segoe UI", 9);
        var flags = TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix;
        TextRenderer.DrawText(e.Graphics, group.Name, bold, new Rectangle(bounds.X, bounds.Y, bounds.Width, 24), Theme.Ink, flags);
        TextRenderer.DrawText(e.Graphics, group.Directory, small, new Rectangle(bounds.X, bounds.Y + 26, bounds.Width, 20), Theme.Secondary, flags);
        TextRenderer.DrawText(e.Graphics, $"{group.Sessions.Count} sessions · {string.Join(" / ", group.Sessions.Select(s => s.Model).Distinct())}", small, new Rectangle(bounds.X, bounds.Y + 47, bounds.Width, 20), Theme.Secondary, flags);
        e.DrawFocusRectangle();
    }
    private void RefreshProjects()
    {
        var previous = CurrentProject?.Key;
        refreshing = true;
        projects.BeginUpdate(); projects.Items.Clear();
        foreach (var group in ProjectGroup.Group(store.Sessions, area, model.Text, source.Text, search.Text)) projects.Items.Add(group);
        var index = Enumerable.Range(0, projects.Items.Count).FirstOrDefault(i => ((ProjectGroup)projects.Items[i]).Key == previous, -1);
        projects.SelectedIndex = index >= 0 ? index : projects.Items.Count > 0 ? 0 : -1;
        projects.EndUpdate(); refreshing = false;
        count.Text = $"{projects.Items.Count} {(area == "Unassigned" ? "unassigned entries" : "projects")}";
        foreach (var button in areaButtons) button.BackColor = (string?)button.Tag == area ? Theme.Sage : Color.White;
        chooseEditor.Text = NativeServices.EditorName(store.Preferences.EditorPath ?? NativeServices.DefaultEditor());
        BindProject(); ShowStorageError();
    }
    private void BindProject()
    {
        refreshing = true; history.Rows.Clear();
        if (CurrentProject is { } group)
            foreach (var session in group.Sessions)
            {
                var index = history.Rows.Add(session.Model, session.Origin, session.CreatedAt.ToLocalTime().ToString("g"), session.Command.Split(' ').LastOrDefault() is { } id ? id[^Math.Min(8, id.Length)..] : "");
                history.Rows[index].Tag = session;
            }
        if (history.Rows.Count > 0) { history.ClearSelection(); history.Rows[0].Selected = true; }
        refreshing = false; ShowSession();
    }
    private void ShowSession()
    {
        var session = CurrentSession;
        foreach (var button in new[] { resume, editor, copy, edit, remove }) button.Enabled = session != null;
        title.Text = CurrentProject?.Name ?? "Your next session belongs here";
        path.Text = CurrentProject?.Directory ?? "Add a screenshot, enter a command, or sync local Codex, Claude, and Grok sessions.";
        command.Text = session?.Command ?? ""; note.Text = session?.Note ?? ""; origin.Text = session == null ? "" : $"Source: {session.Origin} · {(session.DetectedAutomatically ? "Automatically saved" : "Screenshot / manual")}";
        resume.Text = "Resume in " + terminal.Text;
        editor.Text = "Open in " + NativeServices.EditorName(store.Preferences.EditorPath ?? NativeServices.DefaultEditor());
    }
    private void ShowCapture(Session? editing = null, string? image = null)
    {
        ShowLibrary(); using var capture = new CaptureWindow(editing);
        if (image != null) capture.Shown += async (_, _) => await capture.ReadImage(image);
        if (capture.ShowDialog(this) == DialogResult.OK && capture.Result is { } session) Act(() => { store.Upsert(session); area = ProjectPaths.Area(session.ProjectDirectory); RefreshProjects(); });
    }
    private void ChooseScreenshot()
    {
        ShowLibrary(); using var picker = new OpenFileDialog { Title = "Choose a terminal screenshot", Filter = "Screenshots|*.png;*.jpg;*.jpeg;*.bmp;*.tif;*.tiff" };
        if (picker.ShowDialog(this) == DialogResult.OK) ShowCapture(image: picker.FileName);
    }
    private ContextMenuStrip EditorMenu()
    {
        var menu = new ContextMenuStrip();
        var defaultEditor = NativeServices.DefaultEditor();
        if (defaultEditor != null) menu.Items.Add(NativeServices.EditorName(defaultEditor), null, (_, _) => SelectEditor(defaultEditor));
        if (store.Preferences.EditorPath is { } selected && selected != defaultEditor) menu.Items.Add(NativeServices.EditorName(selected), null, (_, _) => SelectEditor(selected));
        menu.Items.Add("Choose another editor…", null, (_, _) =>
        {
            using var picker = new OpenFileDialog { Filter = "Editor applications (*.exe)|*.exe", Title = "Choose your code editor" };
            if (picker.ShowDialog(this) == DialogResult.OK) SelectEditor(picker.FileName);
        }); return menu;
    }
    private void SelectEditor(string path) => Act(() => { store.Preferences.EditorPath = path; store.SavePreferences(); chooseEditor.Text = NativeServices.EditorName(path); ShowSession(); });
    private async Task Sync()
    {
        if (syncing || IsDisposed) return;
        syncing = true; sync.Enabled = false; message.Text = "Reading local session metadata…";
        try
        {
            var result = await Task.Run(() => SessionDiscovery.Scan(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)));
            if (IsDisposed) return;
            store.Merge(result.Sessions); RefreshProjects(); message.Text = result.Warnings.Count == 0 ? $"Saved on this PC · {store.Sessions.Count} sessions · synced {DateTime.Now:t}" : string.Join(" ", result.Warnings.Take(3)); ShowStorageError();
        }
        catch (Exception error) { if (!IsDisposed) message.Text = "Sync could not finish: " + error.Message; }
        finally { syncing = false; if (!IsDisposed) sync.Enabled = true; }
    }
    private async Task CheckUpdates()
    {
        if (!update.Enabled) return;
        update.Enabled = false;
        try
        {
            var manager = NativeServices.UpdateManager();
            if (!manager.IsInstalled) { MessageBox.Show(this, "Use the Reprise Setup.exe installer to enable in-app updates. Portable copies can be replaced from GitHub Releases.", "Updates"); return; }
            message.Text = "Checking GitHub for updates…";
            var available = await manager.CheckForUpdatesAsync();
            if (available == null) { message.Text = "Reprise is up to date."; MessageBox.Show(this, $"Reprise {NativeServices.Version} is up to date.", "Updates"); return; }
            if (MessageBox.Show(this, $"Reprise {available.TargetFullRelease.Version} is available. Download, install, and restart now?", "Update Reprise", MessageBoxButtons.YesNo, MessageBoxIcon.Information) != DialogResult.Yes) return;
            await manager.DownloadUpdatesAsync(available, progress => { if (!IsDisposed && IsHandleCreated) BeginInvoke((Action)(() => message.Text = $"Downloading update… {progress}%")); });
            store.Save(); exiting = true; tray.Visible = false; manager.ApplyUpdatesAndRestart(available);
        }
        catch (Exception error) { exiting = false; tray.Visible = true; MessageBox.Show(this, "The update could not be installed. " + error.Message, "Update failed", MessageBoxButtons.OK, MessageBoxIcon.Error); }
        finally { if (!IsDisposed) update.Enabled = true; }
    }
    private void ShowStorageError() { if (store.StorageError != null) message.Text = store.StorageError; }
    private void Act(Action action) { try { action(); ShowStorageError(); } catch (Exception error) { MessageBox.Show(this, error.Message, "Reprise", MessageBoxButtons.OK, MessageBoxIcon.Error); } }
    internal void ShowLibrary() { Show(); WindowState = FormWindowState.Normal; Activate(); }
    internal string LayoutReport() => $"Window: {Size}; client: {ClientSize}; root: {Controls[0].Bounds}; heading: {title.Bounds}; directory: {path.Bounds}; history: {history.Bounds}; detail: {history.Parent?.Bounds}; detail client: {history.Parent?.ClientSize}";
    private void Quit() { exiting = true; store.Save(); timer.Stop(); tray.Visible = false; Close(); }
    protected override void WndProc(ref Message message) { if ((uint)message.Msg == Program.ShowLibraryMessage) ShowLibrary(); base.WndProc(ref message); }
    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!exiting && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); }
        else { timer.Stop(); tray.Visible = false; store.Save(); }
        base.OnFormClosing(e);
    }
    protected override void Dispose(bool disposing) { if (disposing) { timer.Dispose(); tray?.Dispose(); } base.Dispose(disposing); }
}
