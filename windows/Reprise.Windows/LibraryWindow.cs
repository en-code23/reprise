using Reprise.Core;

namespace Reprise.Windows;

internal sealed class LibraryWindow : Form
{
    private readonly SessionStore store;
    private readonly NotifyIcon tray;
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 30_000 };
    private readonly ListBox projects = new() { Dock = DockStyle.Fill, DrawMode = DrawMode.OwnerDrawFixed, ItemHeight = 82, BorderStyle = BorderStyle.None, IntegralHeight = false };
    private readonly DataGridView history = new() { ReadOnly = true, AllowUserToAddRows = false, AllowUserToDeleteRows = false, MultiSelect = false, SelectionMode = DataGridViewSelectionMode.FullRowSelect, RowHeadersVisible = false, AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill, BackgroundColor = Color.White, BorderStyle = BorderStyle.None, Height = 160 };
    private readonly ComboBox model = Theme.Combo(["All assistants", "codex", "claude", "grok", "other"]);
    private readonly ComboBox source = Theme.Combo(["Main sessions", "All sources", .. NativeServices.Origins]);
    private readonly ComboBox terminal = Theme.Combo(NativeServices.Terminals);
    private readonly ComboBox libraryArea = Theme.Combo(["Projects", "Unassigned", "Internal"]);
    private readonly TextBox search = new() { PlaceholderText = "Search folder names", AccessibleName = "Search folder names", Dock = DockStyle.Fill };
    private readonly Label title = Theme.Label("Your next session belongs here", 22, true), path = Theme.Label("Add a screenshot, enter a command, or sync local sessions."), message = Theme.Label("Saved on this PC", 9);
    private readonly TextBox command = new() { AutoSize = false, ReadOnly = true, Multiline = true, WordWrap = true, MinimumSize = new Size(0, 65), Height = 65, Font = new Font("Consolas", 10), BorderStyle = BorderStyle.FixedSingle };
    private readonly TextBox note = new() { AutoSize = false, ReadOnly = true, Multiline = true, ScrollBars = ScrollBars.Vertical, MinimumSize = new Size(0, 110), Height = 110, BorderStyle = BorderStyle.FixedSingle };
    private readonly Label origin = Theme.Label("", 9), count = Theme.Label("Projects", 11, true);
    private readonly Button resume, editor, copy, edit, remove, sync, update, chooseEditor;
    private bool refreshing, syncing, exiting;
    private string area = "Projects";
    private ProjectGroup? CurrentProject => projects.SelectedItem as ProjectGroup;
    private Session? CurrentSession => history.SelectedRows.Count > 0 ? history.SelectedRows[0].Tag as Session : CurrentProject?.Latest;

    internal LibraryWindow(SessionStore store, bool smoke = false)
    {
        this.store = store;
        Text = "Reprise"; Font = new Font("Segoe UI", 10); BackColor = Theme.Paper; ForeColor = Theme.Ink;
        Icon = NativeServices.LoadIcon(); MinimumSize = new Size(860, 640); Size = new Size(1040, 760); StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        resume = Theme.Button("Resume", (_, _) => Act(() => NativeServices.Resume(CurrentSession!, store.Preferences.Terminal)), true);
        editor = Theme.Button("Open in editor", (_, _) => OpenCurrentEditor());
        copy = Theme.Button("Copy command", (_, _) => Act(() => { Clipboard.SetText(CurrentSession!.Command); message.Text = "Resume command copied."; }));
        edit = Theme.Button("Rename / edit", (_, _) => ShowCapture(CurrentSession));
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
        var root = new SplitContainer { Size = new Size(1040, 760), SplitterDistance = 280, SplitterWidth = 1, FixedPanel = FixedPanel.Panel1, Panel1MinSize = 240, Panel2MinSize = 560, Dock = DockStyle.Fill };
        Controls.Add(root);
        var sidebar = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 4, Padding = new Padding(12), BackColor = Theme.Paper };
        sidebar.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        sidebar.RowStyles.Add(new RowStyle(SizeType.Absolute, 44)); sidebar.RowStyles.Add(new RowStyle(SizeType.Absolute, 44));
        sidebar.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); sidebar.RowStyles.Add(new RowStyle(SizeType.Absolute, 44));
        root.Panel1.Controls.Add(sidebar);
        libraryArea.Dock = DockStyle.Fill;
        libraryArea.SelectedIndexChanged += (_, _) => { if (!refreshing) { area = libraryArea.Text; RefreshProjects(); } };
        sidebar.Controls.Add(libraryArea, 0, 0);
        search.Margin = new Padding(0, 4, 0, 8); search.TextChanged += (_, _) => RefreshProjects(); sidebar.Controls.Add(search, 0, 1);
        projects.BackColor = Theme.Paper; projects.ItemHeight = 66; projects.Margin = new Padding(0);
        projects.DrawItem += DrawProject; projects.SelectedIndexChanged += (_, _) => { if (!refreshing) BindProject(); };
        sidebar.Controls.Add(projects, 0, 2);
        var footer = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, Margin = new Padding(0) };
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); footer.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 60)); footer.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 84));
        count.Font = new Font(Font.FontFamily, 9); count.Dock = DockStyle.Fill; count.TextAlign = ContentAlignment.MiddleLeft;
        sync.Text = "Sync"; sync.AutoSize = false; sync.Dock = DockStyle.Fill; sync.Margin = new Padding(0, 4, 4, 0);
        sync.MinimumSize = new Size(0, 36);
        sync.Padding = Padding.Empty;
        var settings = Theme.Button("Settings", (_, _) => ShowSettings()); settings.AutoSize = false; settings.Dock = DockStyle.Fill; settings.Margin = new Padding(0, 4, 0, 0);
        settings.MinimumSize = new Size(0, 36);
        settings.Padding = Padding.Empty;
        footer.Controls.Add(count, 0, 0); footer.Controls.Add(sync, 1, 0); footer.Controls.Add(settings, 2, 0); sidebar.Controls.Add(footer, 0, 3);

        var main = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 6, Padding = new Padding(20, 12, 20, 0), BackColor = Color.White, Margin = new Padding(0) };
        main.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        foreach (var height in new[] { 48, 142 }) main.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
        main.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); main.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
        var detailRow = new RowStyle(SizeType.Absolute, 0); main.RowStyles.Add(detailRow); main.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
        root.Panel2.Controls.Add(main);
        var toolbar = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false, Margin = new Padding(0) };
        var filters = Theme.Button("Filter", (_, _) => { });
        filters.Click += (_, _) =>
        {
            var menu = new ContextMenuStrip();
            var assistants = new ToolStripMenuItem("Assistant"); var sources = new ToolStripMenuItem("Source");
            foreach (var item in model.Items.Cast<string>())
            {
                var option = new ToolStripMenuItem(item) { Checked = model.Text == item };
                option.Click += (_, _) => { model.SelectedItem = item; filters.Text = model.SelectedIndex > 0 || source.SelectedIndex != 0 ? "Filtered" : "Filter"; };
                assistants.DropDownItems.Add(option);
            }
            foreach (var item in source.Items.Cast<string>())
            {
                var option = new ToolStripMenuItem(item) { Checked = source.Text == item };
                option.Click += (_, _) => { source.SelectedItem = item; filters.Text = model.SelectedIndex > 0 || source.SelectedIndex != 0 ? "Filtered" : "Filter"; };
                sources.DropDownItems.Add(option);
            }
            menu.Items.AddRange([assistants, sources]); menu.Show(filters, new Point(0, filters.Height));
        };
        model.SelectedIndexChanged += (_, _) => RefreshProjects(); source.SelectedIndexChanged += (_, _) => RefreshProjects();
        toolbar.Controls.Add(filters); toolbar.Controls.Add(Theme.Button("Add session", (_, _) => ShowCapture()));
        toolbar.Controls.Add(Theme.Button("Add screenshot…", (_, _) => ChooseScreenshot())); main.Controls.Add(toolbar, 0, 0);
        var heading = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 3, Margin = new Padding(0) };
        heading.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        heading.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 44));
        heading.RowStyles.Add(new RowStyle(SizeType.Absolute, 40)); heading.RowStyles.Add(new RowStyle(SizeType.Absolute, 32)); heading.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        title.Font = new Font(Font.FontFamily, 18, FontStyle.Bold); title.Dock = DockStyle.Fill; title.AutoSize = false; title.AutoEllipsis = true;
        path.Dock = DockStyle.Fill; path.AutoSize = false; path.AutoEllipsis = true; path.ForeColor = Theme.Secondary;
        heading.Controls.Add(title, 0, 0); heading.Controls.Add(path, 0, 1);
        heading.SetColumnSpan(path, 2);
        var actions = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = true, Margin = new Padding(0), Padding = new Padding(0, 6, 0, 0) };
        var more = Theme.Button("…", (_, _) => { });
        more.AccessibleName = "Session actions"; more.MinimumSize = new Size(36, 36); more.AutoSize = false; more.Size = new Size(40, 36); more.Margin = new Padding(0);
        more.Click += (_, _) =>
        {
            var menu = new ContextMenuStrip();
            menu.Items.Add("Rename / edit session…", null, (_, _) => edit.PerformClick());
            menu.Items.Add("Remove from library", null, (_, _) => remove.PerformClick()); menu.Show(more, new Point(0, more.Height));
        };
        heading.Controls.Add(more, 1, 0);
        actions.Controls.AddRange([resume, copy, editor]); heading.Controls.Add(actions, 0, 2); heading.SetColumnSpan(actions, 2); main.Controls.Add(heading, 0, 1);
        history.Dock = DockStyle.Fill; history.Margin = new Padding(0); history.EnableHeadersVisualStyles = false;
        history.ColumnHeadersDefaultCellStyle.BackColor = Theme.Paper; history.ColumnHeadersDefaultCellStyle.ForeColor = Theme.Secondary;
        history.ColumnHeadersDefaultCellStyle.SelectionBackColor = Theme.Paper; history.ColumnHeadersDefaultCellStyle.SelectionForeColor = Theme.Secondary;
        history.ColumnHeadersHeightSizeMode = DataGridViewColumnHeadersHeightSizeMode.AutoSize; history.RowTemplate.Height = 48;
        history.DefaultCellStyle.SelectionBackColor = Theme.Sage; history.DefaultCellStyle.SelectionForeColor = Theme.Ink; history.DefaultCellStyle.Padding = new Padding(5);
        history.CellBorderStyle = DataGridViewCellBorderStyle.SingleHorizontal; history.GridColor = Theme.Paper;
        history.Columns.Add("Name", "Session"); history.Columns.Add("Assistant", "Assistant"); history.Columns.Add("Source", "Source"); history.Columns.Add("Updated", "Saved");
        history.Columns[0].FillWeight = 180; history.Columns[1].FillWeight = 70; history.Columns[2].FillWeight = 100; history.Columns[3].FillWeight = 70;
        history.CellDoubleClick += (_, e) => { if (e.RowIndex >= 0) ShowCapture(CurrentSession); };
        history.SelectionChanged += (_, _) => { if (!refreshing) ShowSession(); }; main.Controls.Add(history, 0, 2);
        var details = new CheckBox { Text = "Session details", Appearance = Appearance.Button, AutoSize = true, Margin = new Padding(0, 8, 0, 0), FlatStyle = FlatStyle.Flat };
        details.FlatAppearance.BorderSize = 0; main.Controls.Add(details, 0, 3);
        var sessionDetails = new TabControl { Dock = DockStyle.Fill, Visible = false, Margin = new Padding(0, 4, 0, 8) };
        var commandPage = new TabPage("Resume command"); var notePage = new TabPage("Project note");
        command.Dock = DockStyle.Fill; note.Dock = DockStyle.Fill; command.MinimumSize = Size.Empty; note.MinimumSize = Size.Empty;
        commandPage.Controls.Add(command); notePage.Controls.Add(note); sessionDetails.TabPages.AddRange([commandPage, notePage]); main.Controls.Add(sessionDetails, 0, 4);
        details.CheckedChanged += (_, _) => { sessionDetails.Visible = details.Checked; detailRow.Height = details.Checked ? 150 : 0; };
        message.Dock = DockStyle.Fill; message.AutoSize = false; message.ForeColor = Theme.Secondary; message.TextAlign = ContentAlignment.MiddleLeft;
        message.AutoEllipsis = true; main.Controls.Add(message, 0, 5);
        terminal.SelectedItem = NativeServices.Terminals.Contains(store.Preferences.Terminal) ? store.Preferences.Terminal : "PowerShell";
        terminal.SelectedIndexChanged += (_, _) => Act(() => { store.Preferences.Terminal = terminal.Text; store.SavePreferences(); ShowSession(); });
    }

    private Form? settingsWindow;
    private void ShowSettings()
    {
        if (settingsWindow == null)
        {
            settingsWindow = new Form { Text = "Reprise Settings", Icon = Icon, Font = Font, ClientSize = new Size(440, 410), FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false, StartPosition = FormStartPosition.CenterParent, BackColor = Theme.Paper };
            var form = new FlowLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(24), FlowDirection = FlowDirection.TopDown, WrapContents = false };
            var automatic = new CheckBox { Text = "Automatically save local sessions", AutoSize = true, Checked = store.Preferences.AutoDiscovery, Margin = new Padding(0, 0, 0, 20) };
            automatic.CheckedChanged += async (_, _) => { Act(() => { store.Preferences.AutoDiscovery = automatic.Checked; store.SavePreferences(); }); if (automatic.Checked) await Sync(); };
            form.Controls.Add(automatic); form.Controls.Add(Theme.Label("Default terminal", 10, true)); terminal.Width = 360; form.Controls.Add(terminal);
            form.Controls.Add(Theme.Label("Default editor", 10, true)); chooseEditor.Width = 360; chooseEditor.AutoSize = false; form.Controls.Add(chooseEditor);
            form.Controls.Add(Theme.Label("Updates", 10, true)); form.Controls.Add(update);
            form.Controls.Add(Theme.Button("Restore removed sessions", async (_, _) => { Act(store.RestoreRemoved); await Sync(); }));
            form.Controls.Add(Theme.Button("Open data folder", (_, _) => NativeServices.OpenUrl(store.DataDirectory)));
            form.Controls.Add(Theme.Label("Reprise " + NativeServices.Version + " · Saved on this PC", 9));
            settingsWindow.Controls.Add(form);
            settingsWindow.FormClosing += (_, e) => { if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; settingsWindow.Hide(); } };
        }
        settingsWindow.Show(this); settingsWindow.Activate();
    }
    private void DrawProject(object? sender, DrawItemEventArgs e)
    {
        if (e.Index < 0 || projects.Items[e.Index] is not ProjectGroup group) return;
        var selected = (e.State & DrawItemState.Selected) != 0;
        using var fill = new SolidBrush(selected ? Theme.Sage : Theme.Paper); e.Graphics.FillRectangle(fill, e.Bounds);
        var bounds = Rectangle.Inflate(e.Bounds, -10, -8);
        using var bold = new Font(Font, FontStyle.Bold);
        using var small = new Font("Segoe UI", 9);
        var flags = TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix;
        TextRenderer.DrawText(e.Graphics, group.Name, bold, new Rectangle(bounds.X, bounds.Y, bounds.Width, 24), Theme.Ink, flags);
        TextRenderer.DrawText(e.Graphics, group.Directory, small, new Rectangle(bounds.X, bounds.Y + 26, bounds.Width, 20), Theme.Secondary, flags);
        e.DrawFocusRectangle();
    }
    private void RefreshProjects()
    {
        var previous = CurrentProject?.Key;
        refreshing = true;
        libraryArea.SelectedItem = area;
        projects.BeginUpdate(); projects.Items.Clear();
        foreach (var group in ProjectGroup.Group(store.Sessions, area, model.Text, source.Text, search.Text)) projects.Items.Add(group);
        var index = Enumerable.Range(0, projects.Items.Count).FirstOrDefault(i => ((ProjectGroup)projects.Items[i]).Key == previous, -1);
        projects.SelectedIndex = index >= 0 ? index : projects.Items.Count > 0 ? 0 : -1;
        projects.EndUpdate(); refreshing = false;
        count.Text = $"{projects.Items.Count} {(area == "Unassigned" ? "unassigned entries" : "projects")}";
        chooseEditor.Text = NativeServices.EditorName(store.Preferences.EditorPath ?? NativeServices.DefaultEditor());
        BindProject(); ShowStorageError();
    }
    private void BindProject()
    {
        refreshing = true; history.Rows.Clear();
        if (CurrentProject is { } group)
            foreach (var session in group.Sessions)
            {
                var index = history.Rows.Add(session.DisplayName, session.Model, session.HasLocalHistory == false ? "History not local" : session.Origin, session.CreatedAt.ToLocalTime().ToString("MMM d"));
                history.Rows[index].Tag = session;
                history.Rows[index].Cells[0].ToolTipText = session.DisplayName + "\n" + session.Command;
                history.Rows[index].Cells[2].ToolTipText = session.Origin;
                history.Rows[index].Cells[3].ToolTipText = session.CreatedAt.ToLocalTime().ToString("f");
            }
        if (history.Rows.Count > 0) { history.ClearSelection(); history.Rows[0].Selected = true; }
        refreshing = false; ShowSession();
    }
    private void ShowSession()
    {
        var session = CurrentSession;
        foreach (var button in new[] { resume, editor, copy, edit, remove }) button.Enabled = session != null;
        resume.Enabled = session != null && session.HasLocalHistory != false;
        title.Text = CurrentProject?.Name ?? "Your next session belongs here";
        path.Text = CurrentProject?.Directory ?? "Add a screenshot, enter a command, or sync local Codex, Claude, and Grok sessions.";
        command.Text = session?.Command ?? ""; note.Text = session?.Note ?? ""; origin.Text = session == null ? "" : $"Source: {session.Origin} · {(session.DetectedAutomatically ? "Automatically saved" : "Screenshot / manual")}";
        resume.Text = "Resume"; resume.AccessibleDescription = "Resume in " + terminal.Text;
        var selectedEditor = store.Preferences.EditorPath ?? NativeServices.DefaultEditor();
        editor.Text = selectedEditor == null ? "Choose editor…" : "Open in " + NativeServices.EditorName(selectedEditor);
        if (session?.HasLocalHistory == false) message.Text = "History is not on this PC. Open this conversation in Codex, then sync.";
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
    private void OpenCurrentEditor()
    {
        if (CurrentSession is not { } session) return;
        Act(() =>
        {
            NativeServices.RequireDirectory(session);
            var selected = store.Preferences.EditorPath ?? NativeServices.DefaultEditor();
            if (selected == null || !File.Exists(selected))
            {
                using var picker = new OpenFileDialog { Filter = "Editor applications (*.exe)|*.exe", Title = "Choose your code editor" };
                if (picker.ShowDialog(this) != DialogResult.OK) return;
                selected = picker.FileName; SelectEditor(selected);
            }
            NativeServices.OpenEditor(session, selected); message.Text = "Project opened. Resume command copied.";
        });
    }
    private async Task Sync()
    {
        if (syncing || IsDisposed) return;
        syncing = true; sync.Enabled = false; message.Text = "Reading local session metadata…";
        try
        {
            var result = await Task.Run(() => SessionDiscovery.Scan(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)));
            if (IsDisposed) return;
            store.Merge(result.Sessions); RefreshProjects(); message.Text = result.Warnings.Count == 0 ? $"Saved on this PC · {store.Sessions.Count} sessions · synced {DateTime.Now:t}" : string.Join(" ", result.Warnings.Take(3)); ShowSession(); ShowStorageError();
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
    internal Form SettingsPreview() { ShowSettings(); return settingsWindow!; }
    internal void ValidateHorizontalLayout()
    {
        if (history.Height < 160 || projects.Width < 200) throw new InvalidOperationException("Session history or project navigation collapsed during layout.");
        var client = RectangleToScreen(ClientRectangle);
        void Inspect(Control parent)
        {
            foreach (Control control in parent.Controls)
            {
                if (!control.Visible) continue;
                if (control is Button && parent is FlowLayoutPanel { AutoScroll: false } && !parent.ClientRectangle.Contains(control.Bounds))
                    throw new InvalidOperationException($"Action is clipped by its container: {control.Text} {control.Bounds}; container {parent.ClientRectangle}");
                if (control is Button or TextBox or ComboBox or Label or DataGridView)
                {
                    var bounds = control.RectangleToScreen(control.ClientRectangle);
                    if (bounds.Left < client.Left || bounds.Right > client.Right)
                        throw new InvalidOperationException($"Control extends outside the window: {control.GetType().Name} {control.Text} {bounds}; window {client}");
                }
                if (control is not DataGridView) Inspect(control);
            }
        }
        Inspect(this);
    }
    private void Quit() { exiting = true; store.Save(); timer.Stop(); tray.Visible = false; Close(); }
    protected override void WndProc(ref Message message) { if ((uint)message.Msg == Program.ShowLibraryMessage) ShowLibrary(); base.WndProc(ref message); }
    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!exiting && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); }
        else { timer.Stop(); tray.Visible = false; store.Save(); }
        base.OnFormClosing(e);
    }
    protected override void Dispose(bool disposing) { if (disposing) { timer.Dispose(); tray?.Dispose(); settingsWindow?.Dispose(); } base.Dispose(disposing); }
}
